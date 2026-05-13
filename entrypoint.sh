#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Jalna Pipeline — Entrypoint
#
# Flow:
#   1. Validate required env vars
#   2. Targeted S3 sync DOWN (single AOI — no mill case statement needed)
#   3. Verify static assets (AOI, parcels, sowing_dates)
#   4. Run notebook via papermill (auto-retry up to MAX_RETRIES)
#   5. Push output notebook to S3 (always — captures failure detail)
#   6. Ingest rasters → GCS + Supabase
#   7. Normalize DB
#   8. Targeted S3 sync UP
#   9. Flush Redis cache
#  10. Notify Microsoft Teams
# ══════════════════════════════════════════════════════════════════════════════

# ── Config ────────────────────────────────────────────────────────────────────
S3_BUCKET="${S3_BUCKET:-carrier-pdfs}"
S3_PREFIX="${S3_PREFIX:-JALNA}"
WORKSPACE="/workspace"
NOTEBOOK="${WORKSPACE}/Jalna_Pipeline.ipynb"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-120}"

# ── Validation ────────────────────────────────────────────────────────────────
REQUIRED_VARS=(FECHA_INICIO FECHA_FIN COPERNICUS_USERNAME COPERNICUS_PASSWORD)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    [[ -z "${!var:-}" ]] && MISSING+=("$var")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "❌ Missing required environment variables: ${MISSING[*]}"
    echo ""
    echo "   Required:"
    echo "     FECHA_INICIO  - inference window start (YYYY-MM-DD)"
    echo "     FECHA_FIN     - inference window end   (YYYY-MM-DD)"
    echo "     COPERNICUS_USERNAME / COPERNICUS_PASSWORD"
    exit 1
fi

# ── Fixed paths (Jalna has one AOI — no mill case statement) ──────────────────
AOI_FILE="Jalana_AOI_extended_east.geojson"
PARCELS_FILE="10_parcels_clean.geojson"
SOWING_FILE="sowing_dates.json"
SITE="JL"

WORK_DIR="jalna-auto"          # equivalent to {mill}-auto: pairs/ + cloudfill_out/
INPUT_DIR="inputs-jalna-auto"  # static inputs (AOI, parcels, sowing)
OUTPUT_DIR="Output-jalna"      # KPI parquets + final tiffs for ingestion

S3_BASE="s3://${S3_BUCKET}/${S3_PREFIX}"
OUTPUT_NB="${WORKSPACE}/notebook_output_JALNA_${TIMESTAMP}.ipynb"
S3_OUTPUT_NB="${S3_BASE}/run-logs/notebook_output_JALNA_${TIMESTAMP}.ipynb"

# ── Teams notification helper ─────────────────────────────────────────────────
teams_notify() {
    local status="$1" message="$2" color
    [[ -z "${TEAMS_WEBHOOK_URL:-}" ]] && return 0
    [[ "${status}" == "success" ]] && color="00C851" || color="FF4444"

    curl -s -X POST "${TEAMS_WEBHOOK_URL}" \
        -H "Content-Type: application/json" \
        -d "{
            \"@type\": \"MessageCard\",
            \"@context\": \"http://schema.org/extensions\",
            \"themeColor\": \"${color}\",
            \"summary\": \"Jalna Pipeline ${status}\",
            \"sections\": [{
                \"activityTitle\": \"Jalna Pipeline — ${status^^}\",
                \"facts\": [
                    { \"name\": \"Site\",       \"value\": \"Jalna (${SITE})\" },
                    { \"name\": \"Window\",     \"value\": \"${FECHA_INICIO} → ${FECHA_FIN}\" },
                    { \"name\": \"Status\",     \"value\": \"${message}\" },
                    { \"name\": \"Timestamp\",  \"value\": \"${TIMESTAMP}\" },
                    { \"name\": \"Run log\",    \"value\": \"${S3_OUTPUT_NB}\" }
                ]
            }]
        }" || echo "⚠️  Teams notification failed"
}

# ── S3 helpers ────────────────────────────────────────────────────────────────
s3_sync_down() {
    local s3_path="$1" local_path="$2"
    echo "   📥  ${s3_path}  →  ${local_path}"
    mkdir -p "${local_path}"
    aws s3 sync "${s3_path}" "${local_path}" --no-progress \
        || echo "      ⚠️  (not found or empty — starting fresh)"
}

s3_sync_up() {
    local local_path="$1" s3_path="$2"
    if [[ -d "${local_path}" ]]; then
        echo "   📤  ${local_path}  →  ${s3_path}"
        aws s3 sync "${local_path}" "${s3_path}" --no-progress \
            --exclude "__pycache__/*" --exclude "*.pyc" \
            --exclude ".ipynb_checkpoints/*"
    else
        echo "   ⊙   ${local_path} does not exist — skipping"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Jalna Pipeline                                                  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  %-64s║\n" "Site:        Jalna (${SITE})"
printf "║  %-64s║\n" "Window:      ${FECHA_INICIO} → ${FECHA_FIN}"
printf "║  %-64s║\n" "Max retries: ${MAX_RETRIES}"
printf "║  %-64s║\n" "S3:          ${S3_BASE}/"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: S3 sync DOWN ──────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📥  Syncing required files from S3"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Static single files
aws s3 cp "${S3_BASE}/static/${AOI_FILE}"     "${WORKSPACE}/${AOI_FILE}"     || echo "⚠️  AOI not found"
aws s3 cp "${S3_BASE}/static/${PARCELS_FILE}" "${WORKSPACE}/${PARCELS_FILE}" || echo "⚠️  Parcels not found"
aws s3 cp "${S3_BASE}/static/${SOWING_FILE}"  "${WORKSPACE}/${SOWING_FILE}"  || echo "⚠️  Sowing dates not found"

# Stateful directories (pairs/ rehydration is the warm-start optimization)
s3_sync_down "${S3_BASE}/${WORK_DIR}/"   "${WORKSPACE}/${WORK_DIR}/"
s3_sync_down "${S3_BASE}/${INPUT_DIR}/"  "${WORKSPACE}/${INPUT_DIR}/"
s3_sync_down "${S3_BASE}/${OUTPUT_DIR}/" "${WORKSPACE}/${OUTPUT_DIR}/"

echo ""
echo "✅  S3 sync down complete"
echo ""

# ── Step 1.1: Verify Critical Assets ──────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍  Verifying critical input assets"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ASSET_ERROR=0
for f in "${AOI_FILE}" "${PARCELS_FILE}" "${SOWING_FILE}"; do
    if [[ -f "${WORKSPACE}/${f}" ]]; then
        echo "   ✅ Found: ${f}"
    else
        echo "   ❌ MISSING: ${f}"
        ASSET_ERROR=1
    fi
done

if [[ ${ASSET_ERROR} -eq 1 ]]; then
    echo ""
    echo "❌ ERROR: Critical assets missing. Path checked: ${S3_BASE}/static/"
    teams_notify "failure" "Missing AOI/parcels/sowing assets in S3."
    exit 1
fi

echo "   🚀 All assets verified."
echo ""

# ── Step 2: Run notebook with retry ───────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀  Running Jalna notebook (max ${MAX_RETRIES} attempts)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ATTEMPT=0
NOTEBOOK_EXIT=1

while [[ ${ATTEMPT} -lt ${MAX_RETRIES} ]]; do
    ATTEMPT=$(( ATTEMPT + 1 ))
    echo ""
    echo "▶  Attempt ${ATTEMPT} / ${MAX_RETRIES}  ($(date '+%Y-%m-%d %H:%M:%S'))"

    if papermill \
        "${NOTEBOOK}" \
        "${OUTPUT_NB}" \
        --no-progress-bar --log-output --kernel python3 \
        --cwd "${WORKSPACE}" \
        -p AOI_GEOJSON       "${WORKSPACE}/${AOI_FILE}" \
        -p PARCELS_GEOJSON   "${WORKSPACE}/${PARCELS_FILE}" \
        -p SOWING_DATES_PATH "${WORKSPACE}/${SOWING_FILE}" \
        -p fecha_inicio_str  "${FECHA_INICIO}" \
        -p fecha_fin_str     "${FECHA_FIN}" \
        -p BASE_DIR          "${WORKSPACE}/${WORK_DIR}" \
        -p RUN_S3_UPLOAD_RAW     False \
        -p RUN_S3_UPLOAD_OUTPUTS False; then
        NOTEBOOK_EXIT=0
        echo ""; echo "✅  Notebook succeeded on attempt ${ATTEMPT}"
        break
    else
        NOTEBOOK_EXIT=$?
        echo ""; echo "⚠️  Attempt ${ATTEMPT} failed (exit ${NOTEBOOK_EXIT})"
        if [[ ${ATTEMPT} -lt ${MAX_RETRIES} ]]; then
            echo "    Waiting ${RETRY_DELAY}s before retry..."
            sleep "${RETRY_DELAY}"
        fi
    fi
done

# ── Step 3: Push output notebook to S3 (always) ───────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📓  Uploading run log notebook"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -f "${OUTPUT_NB}" ]]; then
    aws s3 cp "${OUTPUT_NB}" "${S3_OUTPUT_NB}" --no-progress \
        && echo "   ✅  ${S3_OUTPUT_NB}" \
        || echo "   ⚠️  Failed to upload run log"
else
    echo "   ⚠️  Output notebook not found (papermill may have crashed before writing)"
fi

# ── Step 4: Post-success ingestion + sync up ──────────────────────────────────
if [[ ${NOTEBOOK_EXIT} -eq 0 ]]; then

    # echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # echo "📦  Ingesting Rasters to GCS & Supabase"
    # echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # python3 /workspace/ingest_rasters.py "${WORKSPACE}/${WORK_DIR}/cloudfill_out" || {
    #     echo "❌ Ingestion failed!"
    #     teams_notify "failure" "Ingestion phase failed for Jalna."
    #     exit 1
    # }

    # echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # echo "🧹  Normalizing Database (SQL Updates)"
    # echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    # python3 /workspace/db_normalize.py || {
    #     echo "❌ SQL Normalization failed!"
    #     exit 1
    # }

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📤  Syncing updated files to S3"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    s3_sync_up "${WORKSPACE}/${WORK_DIR}/"   "${S3_BASE}/${WORK_DIR}/"
    s3_sync_up "${WORKSPACE}/${INPUT_DIR}/"  "${S3_BASE}/${INPUT_DIR}/"
    s3_sync_up "${WORKSPACE}/${OUTPUT_DIR}/" "${S3_BASE}/${OUTPUT_DIR}/"

    echo ""
    echo "✅  S3 sync up complete"
fi

# # ── Step 5: Flush Redis Cache ─────────────────────────────────────────────────
# if [[ -n "${REDIS_FLUSH_URL:-}" && -n "${REDIS_AUTH_TOKEN:-}" ]]; then
#     echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#     echo "🧹  Flushing Redis Cache (Upstash)"
#     echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
#     curl -s -X POST "${REDIS_FLUSH_URL}" \
#          -H "Authorization: Bearer ${REDIS_AUTH_TOKEN}" -d "" \
#          || echo "⚠️  Redis flush failed (non-critical)"
# fi

# ── Step 6: Teams notification ────────────────────────────────────────────────
echo ""
if [[ ${NOTEBOOK_EXIT} -eq 0 ]]; then
    echo "🎉  Jalna pipeline finished successfully"
    teams_notify "success" "Completed after ${ATTEMPT} attempt(s). Results synced to S3."
else
    echo "❌  Jalna pipeline failed after ${MAX_RETRIES} attempts"
    teams_notify "failure" "Failed after ${MAX_RETRIES} attempts. Check run log: ${S3_OUTPUT_NB}"
    exit 1
fi
echo ""