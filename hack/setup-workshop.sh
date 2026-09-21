#!/usr/bin/env bash
# Provision DevConf workshop: one namespace + workshop pod per participant/instructor.
#
# Usage:
#   ./hack/setup-workshop.sh [--dry-run] [--skip-htpasswd] [--skip-deploy]
#
# Environment:
#   PARTICIPANT_COUNT=20  INSTRUCTOR_COUNT=2  WORKSHOP_PREFIX=workshop
#   WORKSHOP_IMAGE=quay.io/.../helmet-workshop:latest
#   HTPASSWD_SECRET=htpasswd-secret  HTPASSWD_NS=openshift-config  HTPASSWD_IDP_NAME=htpasswd
#   WORKSHOP_PASSWORD   If set, use this password for every slot (dev/testing only).
#                       Otherwise each participant/instructor gets a unique random password.
#   COORDINATOR_IMAGE   Optional; defaults from WORKSHOP_IMAGE (helmet-workshop → helmet-workshop-coordinator)
#   COORDINATOR_NAMESPACE  Defaults to workshop-coordinator
#   CONSOLE_URL         OpenShift console URL (auto-detected if unset)
#   RESTRICT_SELF_PROVISIONER  When 1 (default), workshop users cannot create projects
#   RHBK_ADMIN_USER     Optional Keycloak admin username — verified not locked out after setup
#   INSTRUCTOR_PARTICIPANT_ROLE  Role on each participant ns for instructors (default: edit)
#
# When HTPasswd users are enabled, the script also ensures an HTPasswd OAuth IdP exists
# (one-time cluster bootstrap). Existing IdPs (e.g. Keycloak/rhbk) are left unchanged.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
SKIP_HTPASSWD=0
SKIP_COORDINATOR=0
SKIP_DEPLOY=0

usage() {
  cat <<'EOF'
Usage: setup-workshop.sh [options]

Options:
  --dry-run         Print actions only
  --skip-htpasswd   Do not create/update HTPasswd users (use existing IdP)
  --skip-coordinator  Do not deploy the credential handout web app
  --skip-deploy     Create namespaces/RBAC only; no workshop pod
  -h, --help        Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --dry-run) DRY_RUN=1 ;;
  --skip-htpasswd) SKIP_HTPASSWD=1 ;;
  --skip-coordinator) SKIP_COORDINATOR=1 ;;
  --skip-deploy) SKIP_DEPLOY=1 ;;
  -h | --help) usage; exit 0 ;;
  *) die "unknown argument: $1" ;;
  esac
  shift
done

require_cmd oc
require_cmd htpasswd
require_cluster_access

workshop_password_for_slot() {
  local ns="$1"
  if [[ -n "${WORKSHOP_PASSWORD:-}" ]]; then
    if [[ -z "${WORKSHOP_PASSWORD_WARNED:-}" ]]; then
      log "Warning: WORKSHOP_PASSWORD is set; all slots share the same password (dev/testing only)"
      WORKSHOP_PASSWORD_WARNED=1
    fi
    printf '%s' "$WORKSHOP_PASSWORD"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run-%s' "$ns"
    return 0
  fi
  generate_workshop_password
}

# Room code for the coordinator gate (CSV row: coordinator,<code>,NA).
# Generated automatically unless WORKSHOP_CHALLENGE is set in workshop.env.
workshop_challenge_for_session() {
  if [[ -n "${WORKSHOP_CHALLENGE:-}" ]]; then
    printf '%s' "$WORKSHOP_CHALLENGE"
    return 0
  fi
  generate_workshop_challenge
}

append_credentials_coordinator_row() {
  local challenge
  challenge="$(workshop_challenge_for_session)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would append coordinator,***,NA room-code row to credentials CSV"
    return 0
  fi
  echo "coordinator,${challenge},NA" >>"${CREDENTIALS_FILE}.tmp"
  log "Room code for coordinator page: ${challenge} (also in ${CREDENTIALS_FILE} as coordinator row)"
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] $*"
  else
    log "# $*"
    "$@"
  fi
}

create_namespace() {
  local ns="$1"
  if oc get namespace "$ns" >/dev/null 2>&1; then
    log "namespace $ns already exists"
    return 0
  fi
  run oc create namespace "$ns"
  run oc label namespace "$ns" \
    helmet.redhat-appstudio.github.com/workshop=true \
    --overwrite
}

bind_user_to_namespace() {
  local ns="$1"
  local user="$2"
  local role
  role="$(workshop_role_for_namespace "$ns")"
  # Migrate legacy bindings from earlier workshop scripts.
  run oc delete rolebinding workshop-admin -n "$ns" --ignore-not-found
  run oc delete rolebinding workshop-access -n "$ns" --ignore-not-found
  run oc adm policy add-role-to-user "$role" "$user" -n "$ns" --rolebinding-name="workshop-access"
}

# Helmet reads installer ConfigMaps in the current namespace only (namespace admin
# is enough). Cluster-wide ConfigMap list is intentionally not granted.
# IngressController get is still required so .OpenShift.Ingress.Domain is populated.
WORKSHOP_HELMET_CLUSTER_ROLE="${WORKSHOP_HELMET_CLUSTER_ROLE:-workshop-helmet-config-reader}"

ensure_workshop_helmet_cluster_role() {
  # Always apply so rule updates take effect on re-run.
  run oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${WORKSHOP_HELMET_CLUSTER_ROLE}
  labels:
    helmet.redhat-appstudio.github.com/workshop: "true"
rules:
  - apiGroups: ["operator.openshift.io"]
    resources: ["ingresscontrollers"]
    verbs: ["get"]
EOF
}

bind_workshop_sa_helmet_access() {
  local ns="$1"
  local binding="workshop-helmet-config-${ns}"
  run oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${binding}
  labels:
    helmet.redhat-appstudio.github.com/workshop: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${WORKSHOP_HELMET_CLUSTER_ROLE}
subjects:
  - kind: ServiceAccount
    name: workshop
    namespace: ${ns}
EOF
}

bind_instructor_to_participant_namespaces() {
  local instructor_ns="$1"
  local instructor_user="$2"
  local i ns suffix
  suffix="${instructor_ns##*-}"

  log "Granting instructor $instructor_user ${INSTRUCTOR_PARTICIPANT_ROLE} on ${PARTICIPANT_COUNT} participant namespace(s)"
  for ((i = 1; i <= PARTICIPANT_COUNT; i++)); do
    ns="$(participant_namespace "$i")"
    run oc adm policy add-role-to-user "${INSTRUCTOR_PARTICIPANT_ROLE}" "$instructor_user" -n "$ns" \
      --rolebinding-name="workshop-instructor-${suffix}"
  done
}

oauth_identity_provider_names() {
  oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{" "}{end}' 2>/dev/null || true
}

oauth_has_htpasswd_provider() {
  local t
  while IFS= read -r t; do
    [[ "$t" == "HTPasswd" ]] && return 0
  done < <(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.type}{"\n"}{end}' 2>/dev/null || true)
  return 1
}

oauth_htpasswd_secret_name() {
  oc get oauth cluster -o go-template='{{range .spec.identityProviders}}{{if eq .type "HTPasswd"}}{{.htpasswd.fileData.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | head -n1
}

ensure_htpasswd_secret_exists() {
  if oc get secret "$HTPASSWD_SECRET" -n "$HTPASSWD_NS" >/dev/null 2>&1; then
    log "HTPasswd secret $HTPASSWD_NS/$HTPASSWD_SECRET already exists"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  : >"$tmp"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would create empty secret $HTPASSWD_NS/$HTPASSWD_SECRET"
    rm -f "$tmp"
    return 0
  fi

  oc create secret generic "$HTPASSWD_SECRET" \
    --from-file=htpasswd="$tmp" \
    -n "$HTPASSWD_NS" \
    --dry-run=client -o yaml | oc apply -f -
  rm -f "$tmp"
  log "Created empty HTPasswd secret $HTPASSWD_NS/$HTPASSWD_SECRET"
}

add_htpasswd_oauth_provider() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would add HTPasswd OAuth identity provider '${HTPASSWD_IDP_NAME}' -> $HTPASSWD_NS/$HTPASSWD_SECRET"
    return 0
  fi

  oc patch oauth cluster --type=json -p="[
    {
      \"op\": \"add\",
      \"path\": \"/spec/identityProviders/-\",
      \"value\": {
        \"name\": \"${HTPASSWD_IDP_NAME}\",
        \"mappingMethod\": \"claim\",
        \"type\": \"HTPasswd\",
        \"htpasswd\": {
          \"fileData\": {
            \"name\": \"${HTPASSWD_SECRET}\"
          }
        }
      }
    }
  ]"
  log "Added HTPasswd OAuth identity provider '${HTPASSWD_IDP_NAME}' (existing IdPs unchanged: $(oauth_identity_provider_names))"
}

wait_for_authentication_operator() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would wait for clusteroperator/authentication Available=True"
    return 0
  fi

  log "Waiting for clusteroperator/authentication to reconcile OAuth changes..."
  if ! oc wait co/authentication --for=condition=Available=True --timeout=600s >/dev/null 2>&1; then
    log "Warning: authentication operator not Available within 10m; HTPasswd login may need a few more minutes"
  fi
}

ensure_htpasswd_identity() {
  local existing_secret
  log "OAuth identity providers: $(oauth_identity_provider_names)"

  if oauth_has_htpasswd_provider; then
    existing_secret="$(oauth_htpasswd_secret_name)"
    if [[ -n "$existing_secret" && "$existing_secret" != "$HTPASSWD_SECRET" ]]; then
      log "Warning: HTPasswd IdP uses secret '${existing_secret}', not ${HTPASSWD_SECRET}"
      log "  Set HTPASSWD_SECRET=${existing_secret} or update OAuth to use ${HTPASSWD_SECRET}"
    else
      log "HTPasswd OAuth identity provider already configured; will update $HTPASSWD_NS/$HTPASSWD_SECRET only"
    fi
  else
    log "No HTPasswd OAuth identity provider found; bootstrapping alongside existing IdPs"
    ensure_htpasswd_secret_exists
    add_htpasswd_oauth_provider
    wait_for_authentication_operator
  fi
}

# Prevent console users from creating new projects (OpenShift self-provisioner).
# Runs regardless of --skip-htpasswd. Set RESTRICT_SELF_PROVISIONER=0 to skip.
restrict_cluster_self_provisioner() {
  [[ "${RESTRICT_SELF_PROVISIONER:-1}" == "1" ]] || return 0

  local crb="self-provisioners"
  if ! oc get clusterrolebinding "$crb" >/dev/null 2>&1; then
    log "Warning: ClusterRoleBinding $crb not found; cannot restrict project creation"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would restrict self-provisioner (workshop users cannot create projects)"
    return 0
  fi

  local group
  for group in \
    system:authenticated-users \
    system:authenticated \
    system:authenticated:oauth; do
    if oc get clusterrolebinding "$crb" -o jsonpath='{range .subjects[*]}{.kind}{"/"}{.name}{"\n"}{end}' \
      | grep -qx "Group/${group}"; then
      log "Removing self-provisioner from group ${group}"
      oc adm policy remove-cluster-role-from-group self-provisioner "$group"
    fi
  done
  oc adm policy add-cluster-role-to-group self-provisioner system:cluster-admins 2>/dev/null || true

  local sample_user
  sample_user="$(htpasswd_username_for_ns "$(participant_namespace 1)")"
  if oc auth can-i create projectrequests.project.openshift.io \
    --as="$sample_user" --all-namespaces 2>/dev/null | grep -qi '^yes'; then
    log "Tightening ${crb}: only system:cluster-admins may create projects"
    oc patch clusterrolebinding "$crb" --type=json -p='[
      {
        "op": "replace",
        "path": "/subjects",
        "value": [
          {
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "Group",
            "name": "system:cluster-admins"
          }
        ]
      }
    ]'
  fi

  if oc auth can-i create projectrequests.project.openshift.io \
    --as="$sample_user" --all-namespaces 2>/dev/null | grep -qi '^yes'; then
    log "Warning: ${sample_user} can still create projects — check ClusterRoleBindings for self-provisioner"
  else
    log "Verified: workshop accounts cannot create new projects (checked as ${sample_user})"
  fi

  verify_admin_access_after_self_provisioner_restriction
}

# Keycloak / cluster admins are unaffected: rhbk IdP is not changed; cluster-admin role
# still has full access; system:cluster-admins keeps self-provisioner.
verify_admin_access_after_self_provisioner_restriction() {
  local crb="self-provisioners"

  if oc get clusterrolebinding "$crb" -o jsonpath='{range .subjects[*]}{.name}{"\n"}{end}' \
    | grep -qx 'system:cluster-admins'; then
    log "Verified: system:cluster-admins retains self-provisioner (Keycloak admins in that group are OK)"
  else
    log "Restoring self-provisioner for system:cluster-admins"
    oc adm policy add-cluster-role-to-group self-provisioner system:cluster-admins
  fi

  local admin_user="${RHBK_ADMIN_USER:-${CLUSTER_ADMIN_USER:-}}"
  if [[ -z "$admin_user" ]]; then
    log "Optional: set RHBK_ADMIN_USER in workshop.env to verify your Keycloak admin after setup"
    return 0
  fi

  if oc auth can-i '*' '*' --all-namespaces --as="$admin_user" 2>/dev/null | grep -qi '^yes'; then
    log "Verified: ${admin_user} has cluster-admin (full access; not locked out)"
    return 0
  fi
  if oc auth can-i create projectrequests.project.openshift.io \
    --as="$admin_user" --all-namespaces 2>/dev/null | grep -qi '^yes'; then
    log "Verified: ${admin_user} can still create projects"
    return 0
  fi

  log "Warning: ${admin_user} cannot create projects — ensure they are cluster-admin or in system:cluster-admins"
}

append_htpasswd_user() {
  local user="$1"
  local pass="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would update secret $HTPASSWD_SECRET in $HTPASSWD_NS for user $user"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if oc get secret "$HTPASSWD_SECRET" -n "$HTPASSWD_NS" >/dev/null 2>&1; then
    oc get secret "$HTPASSWD_SECRET" -n "$HTPASSWD_NS" -o jsonpath='{.data.htpasswd}' | base64 -d >"$tmp" || true
  fi
  htpasswd -bB "$tmp" "$user" "$pass"
  oc create secret generic "$HTPASSWD_SECRET" \
    --from-file=htpasswd="$tmp" \
    -n "$HTPASSWD_NS" \
    --dry-run=client -o yaml | oc apply -f -
  rm -f "$tmp"
}

deploy_workshop_pod() {
  local ns="$1"
  local working_dir="/home/workshop/helmet-workshop/rewards-workshop"
  if is_instructor_namespace "$ns"; then
    working_dir="/home/workshop/helmet-workshop/rewards-demo"
  fi
  run oc apply -n "$ns" -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workshop
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workshop-self-exec
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: workshop
    namespace: ${ns}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workshop
  labels:
    app: workshop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workshop
  template:
    metadata:
      labels:
        app: workshop
    spec:
      serviceAccountName: workshop
      containers:
        - name: workshop
          image: ${WORKSHOP_IMAGE}
          imagePullPolicy: Always
          command: ["/bin/bash", "-c", "sleep infinity"]
          env:
            - name: HOME
              value: /home/workshop
            - name: WORKSHOP_NAMESPACE
              value: ${ns}
            - name: HELMET_CONFIG_NAMESPACE
              value: ${ns}
            - name: REWARDS_DEMO_HOME
              value: /home/workshop/helmet-workshop/rewards-demo
            - name: REWARDS_WORKSHOP_HOME
              value: /home/workshop/helmet-workshop/rewards-workshop
            - name: WORKSHOP_IMAGE
              value: ${WORKSHOP_IMAGE}
            # Helmet CLI: use in-cluster ServiceAccount auth (no ~/.kube/config in the pod).
            - name: KUBECONFIG
              value: ""
          workingDir: ${working_dir}
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
EOF
}

detect_console_url() {
  local host=""
  host="$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    host="$(oc get ingress console -n openshift-console -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  fi
  if [[ -n "$host" ]]; then
    printf 'https://%s' "$host"
  fi
}

deploy_workshop_coordinator() {
  if [[ "$SKIP_HTPASSWD" -eq 1 || "$SKIP_COORDINATOR" -eq 1 ]]; then
    return 0
  fi

  COORDINATOR_IMAGE="$(resolve_coordinator_image "$WORKSHOP_IMAGE")"
  local console_url="${CONSOLE_URL:-$(detect_console_url)}"
  if [[ -z "$console_url" ]]; then
    die "CONSOLE_URL is unset and OpenShift console route could not be detected"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] coordinator phase in $COORDINATOR_NAMESPACE"
    log "[dry-run]   1. create namespace + credentials secret from $CREDENTIALS_FILE"
    log "[dry-run]   2. deploy coordinator ($COORDINATOR_IMAGE)"
    log "[dry-run]   console URL: $console_url"
    return 0
  fi

  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    die "credentials file missing: $CREDENTIALS_FILE"
  fi

  log "=== Coordinator: namespace + credentials secret ==="
  ensure_coordinator_namespace
  sync_coordinator_credentials_secret

  log "=== Coordinator: deploy application ==="
  deploy_coordinator_application "$console_url"
}

ensure_coordinator_namespace() {
  if ! oc get namespace "$COORDINATOR_NAMESPACE" >/dev/null 2>&1; then
    run oc create namespace "$COORDINATOR_NAMESPACE"
  else
    log "namespace $COORDINATOR_NAMESPACE already exists"
  fi
  run oc label namespace "$COORDINATOR_NAMESPACE" \
    helmet.redhat-appstudio.github.com/workshop-coordinator=true \
    --overwrite
}

sync_coordinator_credentials_secret() {
  local tmp participant_rows
  tmp="$(mktemp)"
  {
    head -n1 "$CREDENTIALS_FILE"
    grep -E '^coordinator,' "$CREDENTIALS_FILE" || true
    grep -E "^${WORKSHOP_PREFIX}-p[0-9]+," "$CREDENTIALS_FILE" || true
  } >"$tmp"
  participant_rows=$(($(wc -l <"$tmp") - 1))
  if [[ "$participant_rows" -le 0 ]]; then
    rm -f "$tmp"
    die "no participant credentials found in $CREDENTIALS_FILE for coordinator queue"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would upload participant-only credentials ($participant_rows slots; instructors excluded)"
    rm -f "$tmp"
    return 0
  fi

  oc create secret generic workshop-credentials \
    --from-file=credentials.csv="$tmp" \
    -n "$COORDINATOR_NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f -
  rm -f "$tmp"
  log "Updated secret workshop-credentials ($participant_rows participant slots; instructors excluded)"
}

deploy_coordinator_application() {
  local console_url="$1"
  local session_secret
  session_secret="$(openssl rand -hex 32)"

  run oc create secret generic workshop-coordinator-config \
    --from-literal=session-secret="$session_secret" \
    -n "$COORDINATOR_NAMESPACE" \
    --dry-run=client -o yaml | oc apply -f -

  run oc apply -n "$COORDINATOR_NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: workshop-coordinator-state
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workshop-coordinator
  labels:
    app: workshop-coordinator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workshop-coordinator
  template:
    metadata:
      labels:
        app: workshop-coordinator
    spec:
      containers:
        - name: coordinator
          image: ${COORDINATOR_IMAGE}
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: CONSOLE_URL
              value: "${console_url}"
            - name: IDP_NAME
              value: "${HTPASSWD_IDP_NAME}"
            - name: CREDENTIALS_PATH
              value: /config/credentials.csv
            - name: STATE_PATH
              value: /data/state.json
            - name: COORDINATOR_SESSION_SECRET
              valueFrom:
                secretKeyRef:
                  name: workshop-coordinator-config
                  key: session-secret
          volumeMounts:
            - name: credentials
              mountPath: /config/credentials.csv
              subPath: credentials.csv
              readOnly: true
            - name: state
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 20
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
      volumes:
        - name: credentials
          secret:
            secretName: workshop-credentials
        - name: state
          persistentVolumeClaim:
            claimName: workshop-coordinator-state
---
apiVersion: v1
kind: Service
metadata:
  name: workshop-coordinator
  labels:
    app: workshop-coordinator
spec:
  selector:
    app: workshop-coordinator
  ports:
    - name: http
      port: 80
      targetPort: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: workshop-coordinator
  labels:
    app: workshop-coordinator
spec:
  to:
    kind: Service
    name: workshop-coordinator
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
EOF

  local route_host=""
  for _ in $(seq 1 30); do
    route_host="$(oc get route workshop-coordinator -n "$COORDINATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "$route_host" ]] && break
    sleep 2
  done
  if [[ -n "$route_host" ]]; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
      "${SCRIPT_DIR}/publish-coordinator-url.sh" "https://${route_host}/" \
        || log "Warning: publish-coordinator-url.sh failed (short URL/DNS optional)"
    else
      log "[dry-run] would run publish-coordinator-url.sh for https://${route_host}/"
    fi
  else
    log "Coordinator deployed; route host not ready yet — check: oc get route -n $COORDINATOR_NAMESPACE"
  fi
}

provision_slot() {
  local ns="$1"
  local user
  user="$(htpasswd_username_for_ns "$ns")"
  local pass
  pass="$(workshop_password_for_slot "$ns")"

  log "=== Provisioning $ns (user: $user) ==="
  create_namespace "$ns"
  bind_user_to_namespace "$ns" "$user"
  bind_workshop_sa_helmet_access "$ns"
  if is_instructor_namespace "$ns"; then
    bind_instructor_to_participant_namespaces "$ns" "$user"
  fi

  if [[ "$SKIP_HTPASSWD" -eq 0 ]]; then
    append_htpasswd_user "$user" "$pass"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      ensure_output_dir
      echo "${user},${pass},${ns}" >>"${CREDENTIALS_FILE}.tmp"
    fi
  fi

  if [[ "$SKIP_DEPLOY" -eq 0 ]]; then
    deploy_workshop_pod "$ns"
  fi
}

main() {
  restrict_cluster_self_provisioner
  ensure_workshop_helmet_cluster_role

  if [[ "$SKIP_HTPASSWD" -eq 0 ]]; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
      ensure_output_dir
      : >"${CREDENTIALS_FILE}.tmp"
      echo "username,password,namespace" >"${CREDENTIALS_FILE}.tmp"
    fi
    ensure_htpasswd_identity
  fi

  local i ns
  for ((i = 1; i <= PARTICIPANT_COUNT; i++)); do
    ns="$(participant_namespace "$i")"
    provision_slot "$ns"
  done
  for ((i = 1; i <= INSTRUCTOR_COUNT; i++)); do
    ns="$(instructor_namespace "$i")"
    provision_slot "$ns"
  done

  if [[ "$SKIP_HTPASSWD" -eq 0 ]]; then
    if [[ "$DRY_RUN" -eq 0 ]]; then
      append_credentials_coordinator_row
      mv "${CREDENTIALS_FILE}.tmp" "$CREDENTIALS_FILE"
      log "Done. Credentials: $CREDENTIALS_FILE"
    else
      log "[dry-run] would write credentials to $CREDENTIALS_FILE"
    fi
    log "Console login: choose identity provider '${HTPASSWD_IDP_NAME}' (HTPasswd)"
    deploy_workshop_coordinator
  else
    log "Done. Namespaces and workshop Deployments created (HTPasswd skipped)."
    log "Console users were not created; 'User not found' warnings are expected."
  fi
}

main "$@"
