#!/usr/bin/env bash
# Capacity / soak helper: drive make build → config → topology → deploy inside
# every workshop pod (participants, optionally instructors), in parallel, and
# report worker CPU/memory pressure before and after.
#
# Uses rewards-demo (complete installer) so deploy succeeds without lab fixes.
# Leaves releases/PVCs in place — use cleanup-workshop.sh or helm uninstall to tear down.
#
# Prerequisites: oc logged in as cluster-admin (or equivalent), workshop pods Ready.
#
# Usage:
#   set -a && source hack/workshop.env && set +a
#   ./hack/capacity-test.sh
#   ./hack/capacity-test.sh --parallel 5
#   ./hack/capacity-test.sh --include-instructors
#   ./hack/capacity-test.sh --skip-deploy          # build/config/topology only
#   ./hack/capacity-test.sh --namespaces workshop-p01,workshop-p02
#
# Environment:
#   PARTICIPANT_COUNT / INSTRUCTOR_COUNT / WORKSHOP_PREFIX — from workshop.env
#   PARALLEL              Max concurrent pods (default: all selected)
#   CAPACITY_LOG_DIR      Log directory (default: out/capacity-test-<timestamp>)
#   OC_EXEC_TIMEOUT       Per-pod oc exec timeout (default: 45m)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/hack/lib/common.sh"

PARALLEL="${PARALLEL:-0}"
INCLUDE_INSTRUCTORS=0
SKIP_DEPLOY=0
NAMESPACE_FILTER=""
OC_EXEC_TIMEOUT="${OC_EXEC_TIMEOUT:-45m}"
INSTALLER_DIR="/home/workshop/helmet-workshop/rewards-demo"
INSTALLER_BIN="./rewards-demo"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --parallel)
    PARALLEL="$2"
    shift 2
    ;;
  --include-instructors)
    INCLUDE_INSTRUCTORS=1
    shift
    ;;
  --skip-deploy)
    SKIP_DEPLOY=1
    shift
    ;;
  --namespaces)
    NAMESPACE_FILTER="$2"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "Unknown option: $1 (try --help)"
    ;;
  esac
done

require_cmd oc
require_cmd date
require_cluster_access

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAPACITY_LOG_DIR="${CAPACITY_LOG_DIR:-${OUTPUT_DIR}/capacity-test-${TIMESTAMP}}"
ensure_output_dir
mkdir -p "$CAPACITY_LOG_DIR"

# --- namespace selection -------------------------------------------------------

list_target_namespaces() {
  local i ns
  if [[ -n "$NAMESPACE_FILTER" ]]; then
    local _ns
    IFS=',' read -r -a _ns_list <<<"$NAMESPACE_FILTER"
    for _ns in "${_ns_list[@]}"; do
      _ns="$(echo "$_ns" | tr -d '[:space:]')"
      [[ -n "$_ns" ]] || continue
      printf '%s\n' "$_ns"
    done
    return 0
  fi
  for ((i = 1; i <= PARTICIPANT_COUNT; i++)); do
    printf '%s\n' "$(participant_namespace "$i")"
  done
  if [[ "$INCLUDE_INSTRUCTORS" -eq 1 ]]; then
    for ((i = 1; i <= INSTRUCTOR_COUNT; i++)); do
      printf '%s\n' "$(instructor_namespace "$i")"
    done
  fi
}

TARGET_NS=()
while IFS= read -r _ns; do
  [[ -n "$_ns" ]] || continue
  TARGET_NS+=("$_ns")
done < <(list_target_namespaces)
[[ ${#TARGET_NS[@]} -gt 0 ]] || die "no target namespaces selected"

if [[ "$PARALLEL" -eq 0 ]]; then
  PARALLEL="${#TARGET_NS[@]}"
fi
[[ "$PARALLEL" -ge 1 ]] || die "PARALLEL must be >= 1"

# --- resource snapshot --------------------------------------------------------

# Dedicated workers: worker role without control-plane (compact masters also
# carry worker — exclude them so capacity reflects lab scheduling).
worker_node_names() {
  if oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' \
    -o name >/dev/null 2>&1; then
    oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    oc get nodes -l node-role.kubernetes.io/worker \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  fi
}

snapshot_resources() {
  local label="$1"
  local out="${CAPACITY_LOG_DIR}/resources-${label}.txt"
  {
    echo "# Capacity snapshot: $label ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
    echo
    echo "## Nodes"
    oc get nodes -o wide
    echo
    echo "## Dedicated worker Allocated resources"
    local node
    while IFS= read -r node; do
      [[ -n "$node" ]] || continue
      echo "### $node"
      oc describe "node/$node" | sed -n '/Allocated resources:/,/Events:/p' | head -n 20
      echo
    done < <(worker_node_names)
    echo "## Cluster pods (rewards apps)"
    oc get pods -A -l 'app.kubernetes.io/part-of in (rewards-demo,rewards-workshop)' \
      --no-headers 2>/dev/null | wc -l | awk '{print "rewards pods:", $1}'
    oc get pods -A -l app=workshop --no-headers 2>/dev/null | wc -l | awk '{print "workshop shell pods:", $1}'
    echo
    echo "## Pending pods (any namespace)"
    oc get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null || true
  } | tee "$out"
  log "Wrote $out"
}

# --- per-pod workload ---------------------------------------------------------

workshop_pod_name() {
  local ns="$1"
  oc get pods -n "$ns" -l app=workshop -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

wait_workshop_pod() {
  local ns="$1"
  local i
  for ((i = 1; i <= 60; i++)); do
    if oc get pods -n "$ns" -l app=workshop --no-headers 2>/dev/null | grep -q Running; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Script run inside the workshop container (bash -lc).
remote_capacity_script() {
  local skip_deploy="$1"
  cat <<EOF
set -euo pipefail
cd ${INSTALLER_DIR}
NS="\${WORKSHOP_NAMESPACE:?WORKSHOP_NAMESPACE not set}"
echo "# [\$(hostname)] ns=\$NS cwd=\$(pwd) skip_deploy=${skip_deploy}"
echo "# make build"
make build
echo "# config --create --force"
${INSTALLER_BIN} config --create --force
echo "# topology"
${INSTALLER_BIN} topology
if [[ "${skip_deploy}" != "1" ]]; then
  echo "# deploy"
  ${INSTALLER_BIN} deploy
  echo "# deploy done"
else
  echo "# skip deploy"
fi
echo "# OK \$NS"
EOF
}

run_one_namespace() {
  local ns="$1"
  local logf="${CAPACITY_LOG_DIR}/${ns}.log"
  local pod
  local rc=0

  {
    echo "# === $ns $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    if ! wait_workshop_pod "$ns"; then
      echo "[ERROR] no Running workshop pod in $ns"
      exit 1
    fi
    pod="$(workshop_pod_name "$ns")"
    if [[ -z "$pod" ]]; then
      echo "[ERROR] could not resolve workshop pod in $ns"
      exit 1
    fi
    echo "# pod=$pod"
    oc exec -n "$ns" "$pod" -c workshop --request-timeout="$OC_EXEC_TIMEOUT" -- \
      /bin/bash -lc "$(remote_capacity_script "$SKIP_DEPLOY")"
  } >"$logf" 2>&1 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo "OK  $ns" | tee -a "${CAPACITY_LOG_DIR}/summary.txt"
  else
    echo "FAIL $ns (rc=$rc) → $logf" | tee -a "${CAPACITY_LOG_DIR}/summary.txt"
  fi
  return "$rc"
}

# --- main ---------------------------------------------------------------------

log "Targets (${#TARGET_NS[@]}): ${TARGET_NS[*]}"
log "Parallelism: $PARALLEL"
log "Installer:   $INSTALLER_DIR ($INSTALLER_BIN)"
log "Skip deploy: $SKIP_DEPLOY"
log "Logs:        $CAPACITY_LOG_DIR"
echo

snapshot_resources "before"
echo

: >"${CAPACITY_LOG_DIR}/summary.txt"
fail_count=0
active_pids=()

wait_for_slot() {
  local pid
  local new_pids=()
  local any_done=0
  while [[ "$any_done" -eq 0 ]]; do
    new_pids=()
    for pid in "${active_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
      else
        any_done=1
        if wait "$pid"; then
          :
        else
          fail_count=$((fail_count + 1))
        fi
      fi
    done
    active_pids=()
    if [[ ${#new_pids[@]} -gt 0 ]]; then
      active_pids=("${new_pids[@]}")
    fi
    if [[ "$any_done" -eq 0 ]]; then
      sleep 2
    fi
  done
}

for ns in "${TARGET_NS[@]}"; do
  while [[ ${#active_pids[@]} -ge $PARALLEL ]]; do
    wait_for_slot
  done
  log "Starting $ns ..."
  run_one_namespace "$ns" &
  active_pids+=("$!")
done

# Drain remaining
for pid in "${active_pids[@]}"; do
  if wait "$pid"; then
    :
  else
    fail_count=$((fail_count + 1))
  fi
done

echo
snapshot_resources "after"
echo

log "======== SUMMARY ========"
if [[ -f "${CAPACITY_LOG_DIR}/summary.txt" ]]; then
  sort "${CAPACITY_LOG_DIR}/summary.txt"
fi
log "Failures: $fail_count / ${#TARGET_NS[@]}"
log "Logs:     $CAPACITY_LOG_DIR"
log "Snapshots: ${CAPACITY_LOG_DIR}/resources-before.txt"
log "           ${CAPACITY_LOG_DIR}/resources-after.txt"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
