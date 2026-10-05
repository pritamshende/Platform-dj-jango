#!/usr/bin/env bash
# ============================================================================
# deploy.sh — Server-side deployment script
# ============================================================================

set -euo pipefail

APP_USER="platform"
APP_GROUP="platform"
RELEASES_DIR="/opt/platform/releases"
CURRENT_LINK="/opt/platform/current"
ENV_FILE="/etc/platform/platform.env"
PREV_RELEASE_FILE="/etc/platform/previous_release.txt"
STATIC_DIR="/var/lib/platform/static"
HEALTH_URL="http://127.0.0.1:8000/health/ready/"
LOCK_FILE="/tmp/platform-deploy.lock"

COMMIT_SHA="${1:?Usage: deploy.sh <commit-sha> <s3-artifact-uri>}"
S3_URI="${2:?Usage: deploy.sh <commit-sha> <s3-artifact-uri>}"
RELEASE_DIR="${RELEASES_DIR}/${COMMIT_SHA}"

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fail()  { log "ERROR: $*"; exit 1; }

# ---- Lock Acquisition ----
if ! mkdir "${LOCK_FILE}" 2>/dev/null; then
    fail "Another deployment is in progress"
fi
cleanup() { rmdir "${LOCK_FILE}" 2>/dev/null || true; }
trap cleanup EXIT

command -v rsync >/dev/null || fail "rsync is required but not installed."
command -v aws >/dev/null || fail "aws cli is required but not installed."

PREVIOUS_RELEASE=""
if [ -L "${CURRENT_LINK}" ]; then
    PREVIOUS_RELEASE="$(readlink -f "${CURRENT_LINK}")"
    echo "${PREVIOUS_RELEASE}" > "${PREV_RELEASE_FILE}"
fi

if [ -d "${RELEASE_DIR}" ]; then
    fail "Release directory already exists."
fi

log "Downloading artifact..."
mkdir -p "${RELEASE_DIR}"
aws s3 cp "${S3_URI}" "/tmp/${COMMIT_SHA}.tar.gz"
tar -xzf "/tmp/${COMMIT_SHA}.tar.gz" -C "${RELEASE_DIR}" --strip-components=1
rm -f "/tmp/${COMMIT_SHA}.tar.gz"

log "Creating virtual environment ..."
python3 -m venv "${RELEASE_DIR}/.venv"
"${RELEASE_DIR}/.venv/bin/pip" install --upgrade pip --quiet
"${RELEASE_DIR}/.venv/bin/pip" install -r "${RELEASE_DIR}/requirements.txt" --quiet

log "Running Django deployment checks ..."
set -a; source "${ENV_FILE}"; set +a
# A failure here stops the deployment before activation
"${RELEASE_DIR}/.venv/bin/python" "${RELEASE_DIR}/manage.py" check --deploy 2>&1

log "Running database migrations ..."
"${RELEASE_DIR}/.venv/bin/python" "${RELEASE_DIR}/manage.py" migrate --noinput
"${RELEASE_DIR}/.venv/bin/python" "${RELEASE_DIR}/manage.py" collectstatic --noinput
rsync -a "${RELEASE_DIR}/staticfiles/" "${STATIC_DIR}/"

log "Setting permissions ..."
chown -R root:"${APP_GROUP}" "${RELEASE_DIR}"
chmod -R u=rwX,g=rX,o= "${RELEASE_DIR}"
chmod o+rx /var/lib/platform /var/lib/platform/static

log "Activating release ${COMMIT_SHA} ..."
ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}"

perform_rollback() {
    if [ -n "${PREVIOUS_RELEASE}" ] && [ -d "${PREVIOUS_RELEASE}" ]; then
        log "Rolling back to ${PREVIOUS_RELEASE}..."
        ln -sfn "${PREVIOUS_RELEASE}" "${CURRENT_LINK}"
        systemctl restart platform || fail "Rollback restart failed!"
        
        # Verify rollback health
        sleep 3
        RB_HTTP=$(curl -s --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" -H "Host: platform.example.com" "${HEALTH_URL}" 2>/dev/null || echo "000")
        if [ "${RB_HTTP}" = "200" ]; then
            log "Rollback completed and healthy."
        else
            fail "CRITICAL: Rollback completed but is failing health checks (HTTP ${RB_HTTP})."
        fi
    else
        fail "Cannot rollback: No valid previous release."
    fi
}

log "Restarting platform service ..."
if ! systemctl restart platform; then
    log "Failed to restart platform service."
    perform_rollback
    fail "Deployment failed during service restart"
fi

log "Waiting for application to become healthy ..."
for i in $(seq 1 10); do
    HTTP_CODE=$(curl -s --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" -H "Host: platform.example.com" "${HEALTH_URL}" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ]; then 
        log "Health check passed"
        exit 0
    fi
    if [ "${i}" -eq 10 ]; then
        log "Health check failed after retries."
        perform_rollback
        fail "Deployment failed health check"
    fi
    sleep 3
done
