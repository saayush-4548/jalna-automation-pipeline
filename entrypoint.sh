#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Jalna Pipeline — Entrypoint
# ══════════════════════════════════════════════════════════════════════════════

# ── Config ────────────────────────────────────────────────────────────────────
S3_BUCKET="${S3_BUCKET:-carrier-pdfs}"
S3_PREFIX="${S3_PREFIX:-JALNA}"
WORKSPACE="/workspace"
NOTEBOOK="${WORKSPACE}/Jalna_Pipeline.ipynb"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-120}"

# ── Validation (FECHAS added — entrypoint USES it on the papermill line) ─────
REQUIRED_VARS=(FECHA_INICIO FECHA_FIN FECHAS COPERNICUS_USERNAME COPERNICUS_PASSWORD)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    [[ -z "${!var:-}" ]] && MISSING+=("$var")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "❌ Missing required environment variables: ${MISSING[*]}"
    echo "   Required: FECHA_INICIO, FECHA_FIN, FECHAS, COPERNICUS_USERNAME, COPERNICUS_PASSWORD"
    exit 1
fi

# ── Fixed paths (Jalna has one AOI) ───────────────────────────────────────────
AOI_FILE="Jalana_AOI_extended_east.geojson"
PARCELS_FILE="10_parcels_clean.geojson"
SOWING_FILE="sowing_dates.json"
SITE="JL"

WORK_DIR="jalna-auto"
INPUT_DIR="inputs-jalna-auto"
OUTPUT_DIR="Output-jalna"

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
                    { \"name\": \"Target date\", \"value\": \"${FECHAS}\" },
                    { \"name\": \"Window\",     \"value\": \"${FECHA_INICIO} → ${FECHA_FIN}\" },
                    { \"name\": \"Status\",     \"value\": \"${message}\" },
                    { \"name\": \"Timestamp\",  \"value\": \"${TIMESTAMP}\" },
                    { \"name\": \"Run log\",    \"value\": \"${S3_OUTPUT_NB}\" }
                ]
            }]
        }" || echo "⚠️  Teams notification failed"
}

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
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Jalna Pipeline                                                  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  %-64s║\n" "Site:        Jalna (${SITE})"
printf "║  %-64s║\n" "Target:      ${FECHAS}"
printf "║  %-64s║\n" "Window:      ${FECHA_INICIO} → ${FECHA_FIN}"
printf "║  %-64s║\n" "Max retries: ${MAX_RETRIES}"
printf "║  %-64s║\n" "S3:          ${S3_BASE}/"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: S3 sync DOWN ──────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📥  Syncing static + stateful inputs from S3"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Static files: S3 → /workspace/ (overrides baked-in copies if newer)
aws s3 cp "${S3_BASE}/static/${AOI_FILE}"     "${WORKSPACE}/${AOI_FILE}"     || echo "⚠️  AOI not on S3, using baked-in"
aws s3 cp "${S3_BASE}/static/${PARCELS_FILE}" "${WORKSPACE}/${PARCELS_FILE}" || echo "⚠️  Parcels not on S3, using baked-in"
aws s3 cp "${S3_BASE}/static/${SOWING_FILE}"  "${WORKSPACE}/${SOWING_FILE}"  || echo "⚠️  Sowing not on S3, using baked-in"

s3_sync_down "${S3_BASE}/${WORK_DIR}/"   "${WORKSPACE}/${WORK_DIR}/"
s3_sync_down "${S3_BASE}/${INPUT_DIR}/"  "${WORKSPACE}/${INPUT_DIR}/"
s3_sync_down "${S3_BASE}/${OUTPUT_DIR}/" "${WORKSPACE}/${OUTPUT_DIR}/"
echo ""

# ── Verify critical assets ───────────────────────────────────────────────────
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
    teams_notify "failure" "Missing AOI/parcels/sowing assets in /workspace."
    exit 1
fi
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

    # Only inject parameters that the notebook actually accepts.
    # Cell 2 currently declares: target_date, fecha_inicio_str, fecha_fin_str, BASE_DIR_STR
    # (and IS_PROD path block sets AOI / PARCELS / SOWING / KPI dirs from /workspace)
    if papermill \
        "${NOTEBOOK}" \
        "${OUTPUT_NB}" \
        --no-progress-bar --log-output --kernel python3 \
        --cwd "${WORKSPACE}" \
        -p target_date       "${FECHAS}" \
        -p fecha_inicio_str  "${FECHA_INICIO}" \
        -p fecha_fin_str     "${FECHA_FIN}" \
        -p BASE_DIR_STR      "${WORKSPACE}/${WORK_DIR}"; then
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
if [[ -f "${OUTPUT_NB}" ]]; then
    aws s3 cp "${OUTPUT_NB}" "${S3_OUTPUT_NB}" --no-progress \
        && echo "📓  Run log uploaded: ${S3_OUTPUT_NB}" \
        || echo "⚠️  Failed to upload run log"
else
    echo "⚠️  Output notebook not found (papermill crashed early)"
fi

# ── Step 4: Post-success sync up ──────────────────────────────────────────────
if [[ ${NOTEBOOK_EXIT} -eq 0 ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📤  Syncing updated files to S3"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    s3_sync_up "${WORKSPACE}/${WORK_DIR}/"   "${S3_BASE}/${WORK_DIR}/"
    s3_sync_up "${WORKSPACE}/${INPUT_DIR}/"  "${S3_BASE}/${INPUT_DIR}/"
    s3_sync_up "${WORKSPACE}/${OUTPUT_DIR}/" "${S3_BASE}/${OUTPUT_DIR}/"
fi

# ── Step 5: Notify ────────────────────────────────────────────────────────────
echo ""
if [[ ${NOTEBOOK_EXIT} -eq 0 ]]; then
    echo "🎉  Jalna pipeline finished successfully"
    teams_notify "success" "Completed after ${ATTEMPT} attempt(s)."
else
    echo "❌  Jalna pipeline failed after ${MAX_RETRIES} attempts"
    teams_notify "failure" "Failed after ${MAX_RETRIES} attempts. Run log: ${S3_OUTPUT_NB}"
    exit 1
fi