#!/usr/bin/env bash
# Build and push workshop + coordinator images.
#
# Environment (see hack/workshop.env.example):
#   WORKSHOP_IMAGE      Workshop pod image tag (required for real builds)
#   COORDINATOR_IMAGE   Optional; defaults from WORKSHOP_IMAGE
#   PLATFORM            docker build --platform (default: linux/amd64)
#   CONTAINER_CLI       docker or podman (default: docker)
#
# Options:
#   --no-push           Build only; do not push to the registry
#   --platform TARGET   Same as PLATFORM=...
#
# Requires registry login (e.g. podman login quay.io) before running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../hack/lib/common.sh
source "${ROOT}/hack/lib/common.sh"

# Legacy alias — prefer WORKSHOP_IMAGE everywhere.
if [[ -n "${IMAGE:-}" && -z "${WORKSHOP_IMAGE:-}" ]]; then
  echo "Warning: IMAGE is deprecated; use WORKSHOP_IMAGE instead." >&2
  WORKSHOP_IMAGE="$IMAGE"
fi

WORKSHOP_IMAGE="${WORKSHOP_IMAGE:-quay.io/your-org/helmet-workshop:dev}"
NO_PUSH=0
PLATFORM="${PLATFORM:-linux/amd64}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-push) NO_PUSH=1; shift ;;
  --platform)
    PLATFORM="$2"
    shift 2
    ;;
  -h | --help)
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *)
    echo "Unknown option: $1 (try --help)" >&2
    exit 1
    ;;
  esac
done

COORDINATOR_IMAGE="$(resolve_coordinator_image "$WORKSHOP_IMAGE")"

export DOCKER_BUILDKIT=1
CLI="${CONTAINER_CLI:-docker}"

if ! command -v "$CLI" >/dev/null 2>&1; then
  echo "Container CLI not found: $CLI (install Docker or set CONTAINER_CLI)" >&2
  exit 1
fi

echo "# building workshop:    $WORKSHOP_IMAGE"
"$CLI" build -f "$ROOT/container/Dockerfile" \
  --platform "$PLATFORM" \
  -t "$WORKSHOP_IMAGE" \
  "$ROOT"

echo "# building coordinator: $COORDINATOR_IMAGE"
"$CLI" build -f "$ROOT/coordinator/Dockerfile" \
  --platform "$PLATFORM" \
  -t "$COORDINATOR_IMAGE" \
  "$ROOT"

if [[ "$NO_PUSH" -eq 0 ]]; then
  echo "# pushing $WORKSHOP_IMAGE"
  "$CLI" push "$WORKSHOP_IMAGE"
  echo "# pushing $COORDINATOR_IMAGE"
  "$CLI" push "$COORDINATOR_IMAGE"
  status_line="Built and pushed:"
else
  echo "Skipping registry push (--no-push)"
  status_line="Built (not pushed):"
fi

cat <<EOF

${status_line}
  workshop:    $WORKSHOP_IMAGE
  coordinator: $COORDINATOR_IMAGE

Setup (same WORKSHOP_IMAGE):
  ./hack/setup-workshop.sh
EOF
