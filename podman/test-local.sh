#!/usr/bin/env bash
# Run the regression-evaluator image with podman against a local/reachable PostgreSQL instance.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: IMAGE=<harbor-image:tag> CURRENT_RUN=<uuid> ./podman/test-local.sh

Required env vars:
  IMAGE         Harbor image reference, e.g. harbor.example.com/project/regression-evaluator:1.0.0
  CURRENT_RUN   UUID of the run to evaluate (--current-run)

Optional env vars (defaults shown):
  DB_HOST              host.containers.internal   (podman's host-reachable DNS name)
  DB_PORT              5432
  DB_NAME              perfdb
  DB_USER              perfuser
  DB_PASSWORD          perfpass
  BASELINE_STRATEGY    latest
  OUTPUT_DIR           ./examples                 (mounted as /data in the container)
  OUTPUT_FILE          perf-report-local.html
  RELEASE_GATE         true
  ENABLE_CLUSTERING    true
  LOG_LEVEL            INFO
  HARBOR_USER          (optional) if set, runs `podman login` before pulling
  HARBOR_PASSWORD      required when HARBOR_USER is set

Example:
  IMAGE=harbor.example.com/myproject/regression-evaluator:1.0.0 \
  CURRENT_RUN=11111111-2222-3333-4444-555555555555 \
  DB_PASSWORD=secret \
  ./podman/test-local.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

: "${IMAGE:?Set IMAGE to the Harbor image reference (see --help)}"
: "${CURRENT_RUN:?Set CURRENT_RUN to the run UUID to evaluate (see --help)}"

DB_HOST="${DB_HOST:-host.containers.internal}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-perfdb}"
DB_USER="${DB_USER:-perfuser}"
DB_PASSWORD="${DB_PASSWORD:-perfpass}"
BASELINE_STRATEGY="${BASELINE_STRATEGY:-latest}"
OUTPUT_DIR="${OUTPUT_DIR:-./examples}"
OUTPUT_FILE="${OUTPUT_FILE:-perf-report-local.html}"
RELEASE_GATE="${RELEASE_GATE:-true}"
ENABLE_CLUSTERING="${ENABLE_CLUSTERING:-true}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

if [[ -n "${HARBOR_USER:-}" ]]; then
  podman login --username "$HARBOR_USER" --password "${HARBOR_PASSWORD:?Set HARBOR_PASSWORD when HARBOR_USER is set}" "${IMAGE%%/*}"
fi

podman pull "$IMAGE"

mkdir -p "$OUTPUT_DIR"

args=(
  --db-uri "postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  --current-run "$CURRENT_RUN"
  --baseline-strategy "$BASELINE_STRATEGY"
  --reporters html
  --output "/data/${OUTPUT_FILE}"
  --log-level "$LOG_LEVEL"
)
[[ "$RELEASE_GATE" == "true" ]] && args+=(--release-gate)
[[ "$ENABLE_CLUSTERING" == "true" ]] && args+=(--enable-clustering)

podman run --rm \
  -v "${OUTPUT_DIR}:/data:Z" \
  "$IMAGE" \
  "${args[@]}"

echo "Report written to ${OUTPUT_DIR}/${OUTPUT_FILE}"
