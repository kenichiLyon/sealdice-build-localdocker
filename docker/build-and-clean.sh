#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="docker-compose.artifact.yml"
SERVICE="artifact-builder"
KEEP_IMAGE=0
KEEP_BUILDER_CACHE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: docker/build-and-clean.sh [options]

Options:
  --compose-file <path>      Compose file path (default: docker-compose.artifact.yml)
  --service <name>           Compose service name (default: artifact-builder)
  --keep-image               Keep built image (do not run docker image rm)
  --keep-builder-cache       Keep builder cache (do not run docker builder prune)
  --dry-run                  Print commands only, do not execute
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file)
      COMPOSE_FILE="${2:-}"
      shift 2
      ;;
    --service)
      SERVICE="${2:-}"
      shift 2
      ;;
    --keep-image)
      KEEP_IMAGE=1
      shift
      ;;
    --keep-builder-cache)
      KEEP_BUILDER_CACHE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_PATH="${PROJECT_ROOT}/${COMPOSE_FILE}"

if [[ ! -f "${COMPOSE_PATH}" ]]; then
  echo "Compose file not found: ${COMPOSE_PATH}" >&2
  exit 1
fi

run_step() {
  echo ">> $*"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  "$@"
}

BUILD_EXIT_CODE=0
run_step docker compose -f "${COMPOSE_PATH}" run --build --rm "${SERVICE}" || BUILD_EXIT_CODE=$?

if [[ "${KEEP_IMAGE}" != "1" ]]; then
  run_step docker image rm -f sealdice-core-artifact:local || true
fi

if [[ "${KEEP_BUILDER_CACHE}" != "1" ]]; then
  run_step docker builder prune -af || true
fi

exit "${BUILD_EXIT_CODE}"
