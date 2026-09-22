#!/usr/bin/env bash
#
# Recreate the n8n container with policies/ bind-mounted read-only under ~/.n8n-files.
#
# Docker cannot add a mount to a running container, so the container must be replaced.
# This is safe: all n8n state (workflows, credentials, encryption key, API keys) lives in
# the NAMED VOLUME n8n_data, which is untouched by `docker rm`. Only the container is
# replaced. Downtime is roughly 20 seconds.
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICIES_DIR="${REPO_DIR}/policies"
CONTAINER="n8n"
VOLUME="n8n_data"
IMAGE="n8nio/n8n:latest"

# Must live under ~/.n8n-files. n8n 2.x defaults N8N_RESTRICT_FILE_ACCESS_TO to '~/.n8n-files',
# and the Read/Write File node throws "Access to the file is not allowed." for anything outside
# it. Subdirectories are fine. Overriding the env var would also work, but using the documented
# default keeps this portable to n8n Cloud, where the override isn't available.
MOUNT_PATH="/home/node/.n8n-files/policies"

if [[ ! -d "${POLICIES_DIR}" ]]; then
  echo "error: ${POLICIES_DIR} does not exist" >&2
  exit 1
fi

if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
  echo "error: docker volume '${VOLUME}' not found." >&2
  echo "       Refusing to continue — recreating the container without it would lose" >&2
  echo "       all workflows and credentials." >&2
  exit 1
fi

echo "Volume '${VOLUME}' found — n8n state is safe."
echo "Policies:  ${POLICIES_DIR}"
echo "Mounting:  ${POLICIES_DIR} -> ${MOUNT_PATH} (read-only)"
echo

if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
  echo "Removing existing container '${CONTAINER}'..."
  docker rm -f "${CONTAINER}"
else
  echo "No existing container '${CONTAINER}'."
fi

echo "Starting n8n..."
docker run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  -p 5678:5678 \
  -e GENERIC_TIMEZONE=America/Toronto \
  -e TZ=America/Toronto \
  -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true \
  -e N8N_RUNNERS_ENABLED=true \
  -v "${VOLUME}:/home/node/.n8n" \
  -v "${POLICIES_DIR}:${MOUNT_PATH}:ro" \
  "${IMAGE}"

echo -n "Waiting for n8n to come up"
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null http://localhost:5678/healthz 2>/dev/null; then
    echo " — ready."
    break
  fi
  echo -n "."
  sleep 1
done
echo

echo "Policy files visible inside the container:"
docker exec "${CONTAINER}" ls -1 "${MOUNT_PATH}"

echo
echo "Done. NOTE: the in-memory vector store was cleared by the restart —"
echo "re-run the indexing workflow before using the runtime workflow."
