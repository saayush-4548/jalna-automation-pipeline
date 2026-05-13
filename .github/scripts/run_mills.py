"""
Submit a single Jalna SageMaker Processing Job and wait for completion.

Mirrors rs-pipeline's run_mills.py but collapsed for one site:
  - no mill loop
  - no FECHAS list (Jalna picks inference date inside the notebook)
  - one job submission, one wait, one exit code
"""
import os
import sys
import time
from datetime import datetime

import boto3
from botocore.exceptions import ClientError

# ── Env (set by the workflow `env:` block) ───────────────────────────────────
IMAGE_URI       = os.environ["IMAGE_URI"]
FECHA_INICIO    = os.environ["FECHA_INICIO"]
FECHA_FIN       = os.environ["FECHA_FIN"]
FECHAS          = os.environ["FECHAS"]
INSTANCE_TYPE   = os.environ.get("INSTANCE_TYPE", "ml.m6i.8xlarge")
MAX_RETRIES     = os.environ.get("MAX_RETRIES", "3")
RETRY_DELAY     = os.environ.get("RETRY_DELAY", "120")
SAGEMAKER_ROLE  = os.environ["SAGEMAKER_ROLE"]
AWS_REGION      = os.environ.get("AWS_REGION", "us-east-1")
S3_BUCKET       = os.environ.get("S3_BUCKET", "carrier-pdfs")
S3_PREFIX       = os.environ.get("S3_PREFIX", "JALNA")

# Secrets to forward into the container
PASSTHROUGH_ENV_VARS = [
    "TEAMS_WEBHOOK_URL",
    "COPERNICUS_USERNAME", "COPERNICUS_PASSWORD", "COPERNICUS_CLIENT_ID",
    "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY",
    "DB_CONNECTION_STRING",
]

# ── Build job ────────────────────────────────────────────────────────────────
sm = boto3.client("sagemaker", region_name=AWS_REGION)

timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
job_name = f"jalna-pipeline-{timestamp}"

# Compose container env: pipeline params + secrets
container_env = {
    "FECHA_INICIO": FECHA_INICIO,
    "FECHA_FIN":    FECHA_FIN,
    "FECHAS":       FECHAS,
    "MAX_RETRIES":  MAX_RETRIES,
    "RETRY_DELAY":  RETRY_DELAY,
    "S3_BUCKET":    S3_BUCKET,
    "S3_PREFIX":    S3_PREFIX,
    "AWS_DEFAULT_REGION": AWS_REGION,
}
for var in PASSTHROUGH_ENV_VARS:
    val = os.environ.get(var, "")
    if val:
        container_env[var] = val

print("=" * 70)
print(f"  Submitting Jalna SageMaker Processing Job")
print("=" * 70)
print(f"  Job name      : {job_name}")
print(f"  Image         : {IMAGE_URI}")
print(f"  Instance      : {INSTANCE_TYPE}")
print(f"  Window        : {FECHA_INICIO} → {FECHA_FIN}")
print(f"  S3 prefix     : s3://{S3_BUCKET}/{S3_PREFIX}/")
print(f"  Role          : {SAGEMAKER_ROLE}")
print("=" * 70)

try:
    sm.create_processing_job(
        ProcessingJobName=job_name,
        RoleArn=SAGEMAKER_ROLE,
        AppSpecification={
            "ImageUri": IMAGE_URI,
            # entrypoint.sh is the container's CMD via Dockerfile;
            # override here if you want a different entry script
            "ContainerEntrypoint": ["/bin/bash", "/workspace/entrypoint.sh"],
        },
        ProcessingResources={
            "ClusterConfig": {
                "InstanceCount": 1,
                "InstanceType": INSTANCE_TYPE,
                "VolumeSizeInGB": 100,
            }
        },
        Environment=container_env,
        StoppingCondition={"MaxRuntimeInSeconds": 6 * 60 * 60},  # 6h hard cap
        Tags=[
            {"Key": "Project", "Value": "Jalna"},
            {"Key": "Pipeline", "Value": "rs-pipeline-jalna"},
            {"Key": "TriggeredBy", "Value": "github-actions"},
        ],
    )
except ClientError as e:
    print(f"❌ Failed to create processing job: {e}")
    sys.exit(1)

print(f"✅ Job submitted. Polling for completion...")
print()

# ── Poll ─────────────────────────────────────────────────────────────────────
POLL_INTERVAL = 60   # seconds
last_status = None

while True:
    try:
        resp = sm.describe_processing_job(ProcessingJobName=job_name)
    except ClientError as e:
        print(f"⚠️  describe_processing_job error (will retry): {e}")
        time.sleep(POLL_INTERVAL)
        continue

    status = resp["ProcessingJobStatus"]
    if status != last_status:
        print(f"  [{datetime.utcnow().strftime('%H:%M:%S')}] Status: {status}")
        last_status = status

    if status in ("Completed", "Failed", "Stopped"):
        break

    time.sleep(POLL_INTERVAL)

# ── Final result ─────────────────────────────────────────────────────────────
print()
print("=" * 70)
if status == "Completed":
    print(f"🎉  Jalna job {job_name} completed successfully")
    print("=" * 70)
    sys.exit(0)
else:
    reason = resp.get("FailureReason", "(no failure reason provided)")
    exit_msg = resp.get("ExitMessage", "")
    print(f"❌  Jalna job {job_name} ended with status: {status}")
    print(f"    Failure reason: {reason}")
    if exit_msg:
        print(f"    Exit message  : {exit_msg}")
    print("=" * 70)
    sys.exit(1)