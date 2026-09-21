#!/usr/bin/env bash
# Shared helpers for workshop setup/cleanup.
set -euo pipefail

WORKSHOP_PREFIX="${WORKSHOP_PREFIX:-workshop}"
PARTICIPANT_COUNT="${PARTICIPANT_COUNT:-20}"
INSTRUCTOR_COUNT="${INSTRUCTOR_COUNT:-2}"
# Role instructors get on each participant namespace (view = read-only; edit = help/debug including pod terminal).
INSTRUCTOR_PARTICIPANT_ROLE="${INSTRUCTOR_PARTICIPANT_ROLE:-edit}"
WORKSHOP_IMAGE="${WORKSHOP_IMAGE:-quay.io/your-org/helmet-workshop:latest}"
HTPASSWD_SECRET="${HTPASSWD_SECRET:-htpasswd-secret}"
HTPASSWD_NS="${HTPASSWD_NS:-openshift-config}"
HTPASSWD_IDP_NAME="${HTPASSWD_IDP_NAME:-htpasswd}"
COORDINATOR_NAMESPACE="${COORDINATOR_NAMESPACE:-workshop-coordinator}"
OUTPUT_DIR="${OUTPUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/out}"
CREDENTIALS_FILE="${OUTPUT_DIR}/credentials.csv"

# Load hack/workshop.env when present (gitignored local config).
_workshop_env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/workshop.env"
if [[ -f "$_workshop_env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$_workshop_env_file"
  set +a
fi

# Default COORDINATOR_IMAGE via resolve_coordinator_image from WORKSHOP_IMAGE.
resolve_coordinator_image() {
  local workshop_image="${1:-${WORKSHOP_IMAGE:-}}"
  if [[ -n "${COORDINATOR_IMAGE:-}" ]]; then
    printf '%s' "$COORDINATOR_IMAGE"
    return 0
  fi
  if [[ "$workshop_image" == *helmet-workshop* ]]; then
    printf '%s' "${workshop_image/helmet-workshop/helmet-workshop-coordinator}"
    return 0
  fi
  printf '%s' "quay.io/your-org/helmet-workshop-coordinator:dev"
}

log() { printf '%s\n' "$*"; }
die() { log "[ERROR] $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_cluster_access() {
  [[ "${DRY_RUN:-0}" -eq 1 ]] && return 0
  local server whoami err
  server="$(oc whoami --show-server 2>&1)" || {
    die "not logged in to OpenShift — run: oc login <cluster-url>"
  }
  whoami="$(oc whoami 2>/dev/null || true)"
  if ! oc get namespace default >/dev/null 2>&1; then
    err="$(oc get namespace default 2>&1 || true)"
    die "cannot reach cluster API ($server) as ${whoami:-unknown}: ${err##*$'\n'}"
  fi
  log "OpenShift: $server (user: $whoami)"
}

participant_namespace() {
  local n="$1"
  printf '%s-p%02d' "$WORKSHOP_PREFIX" "$n"
}

instructor_namespace() {
  local n="$1"
  printf '%s-i%02d' "$WORKSHOP_PREFIX" "$n"
}

all_workshop_namespaces() {
  local i ns
  for ((i = 1; i <= PARTICIPANT_COUNT; i++)); do
    ns="$(participant_namespace "$i")"
    printf '%s\n' "$ns"
  done
  for ((i = 1; i <= INSTRUCTOR_COUNT; i++)); do
    ns="$(instructor_namespace "$i")"
    printf '%s\n' "$ns"
  done
}

htpasswd_username_for_ns() {
  # Same as namespace for simplicity (workshop-p01 → user workshop-p01).
  printf '%s' "$1"
}

is_participant_namespace() {
  [[ "$1" =~ ^${WORKSHOP_PREFIX}-p[0-9]+$ ]]
}

is_instructor_namespace() {
  [[ "$1" =~ ^${WORKSHOP_PREFIX}-i[0-9]+$ ]]
}

workshop_role_for_namespace() {
  if is_instructor_namespace "$1"; then
    printf 'admin'
  else
    printf 'edit'
  fi
}

ensure_output_dir() {
  mkdir -p "$OUTPUT_DIR"
}

# Random password per workshop slot (safe for CSV and console login).
generate_workshop_password() {
  local pass
  if command -v openssl >/dev/null 2>&1; then
    pass="$(openssl rand -base64 18 | tr -d '/+="\n,' | head -c 20)"
  else
    pass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  fi
  [[ -n "$pass" ]] || die "failed to generate password for workshop user"
  printf '%s' "$pass"
}

# Room code for the coordinator gate (shorter, no ambiguous chars — easier to read aloud).
generate_workshop_challenge() {
  local code
  if command -v openssl >/dev/null 2>&1; then
    code="$(openssl rand -base64 12 | tr -d '/+="\n,0O1lI' | head -c 10)"
  else
    code="$(LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' </dev/urandom | head -c 10)"
  fi
  [[ -n "$code" ]] || die "failed to generate room code for coordinator"
  printf '%s' "$code"
}
