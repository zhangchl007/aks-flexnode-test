#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
COMMAND="${1:-}"
CLUSTER_ALIAS="${2:-}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy env.example to .env and adjust values." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

run_az_vm_command() {
  local script
  script="$1"

  timeout "${AZ_VM_RUN_COMMAND_TIMEOUT:-10m}" az vm run-command invoke \
    --resource-group "${GPU_RG}" \
    --name "${GPU_VM_NAME}" \
    --command-id RunShellScript \
    --scripts "${script}" \
    --query 'value[].message' \
    -o tsv
}

run_remote() {
  ssh -o ConnectTimeout=30 "${TARGET_HOST}" "$@"
}

copy_to_gpu_host() {
  local source_path target_path target_dir quoted_target quoted_target_dir encoded_payload
  source_path="$1"
  target_path="$2"
  target_dir="$(dirname "${target_path}")"
  printf -v quoted_target '%q' "${target_path}"
  printf -v quoted_target_dir '%q' "${target_dir}"

  run_remote "mkdir -p ${quoted_target_dir} 2>/dev/null || sudo mkdir -p ${quoted_target_dir}; if [[ -e ${quoted_target} && ! -w ${quoted_target} ]]; then sudo rm -f ${quoted_target}; fi" >/dev/null 2>&1 || true

  if scp -o ConnectTimeout=30 "${source_path}" "${TARGET_HOST}:${target_path}"; then
    return 0
  fi

  if [[ -n "${GPU_RG:-}" && -n "${GPU_VM_NAME:-}" ]]; then
    echo "SCP to ${TARGET_HOST} failed; falling back to Azure VM Run Command for ${GPU_RG}/${GPU_VM_NAME}." >&2
    encoded_payload="$(base64 -w 0 "${source_path}")"
    if run_az_vm_command "set -eu; umask 077; printf '%s' '${encoded_payload}' | base64 -d > '${target_path}'; chmod 600 '${target_path}'"; then
      return 0
    fi
    echo "Azure VM Run Command config copy failed or timed out after ${AZ_VM_RUN_COMMAND_TIMEOUT:-10m}." >&2
  fi

  return 1
}

run_on_kube1() {
  run_remote "sudo machinectl shell kube1 /bin/bash -lc '$*'"
}

run_gpu_host_script() {
  local script
  script="$1"
  if ssh -o ConnectTimeout=30 "${TARGET_HOST}" 'bash -s' <<< "${script}"; then
    return 0
  fi
  if [[ -n "${GPU_RG:-}" && -n "${GPU_VM_NAME:-}" ]]; then
    echo "SSH to ${TARGET_HOST} failed; falling back to Azure VM Run Command for ${GPU_RG}/${GPU_VM_NAME}." >&2
    if run_az_vm_command "${script}"; then
      return 0
    fi
    echo "Azure VM Run Command failed or timed out after ${AZ_VM_RUN_COMMAND_TIMEOUT:-10m}." >&2
  fi
  return 1
}

run_gpu_host_root_script() {
  local script
  script="$1"
  run_gpu_host_script "sudo bash -s <<'ROOT_SCRIPT'
${script}
ROOT_SCRIPT
"
}

case "${CLUSTER_ALIAS}" in
  a|A)
    CLUSTER_RG="${CLUSTER_A_RG}"
    CLUSTER_NAME="${CLUSTER_A_NAME}"
    CONFIG_OUT="${ROOT_DIR}/config-A.json"
    ;;
  b|B)
    CLUSTER_RG="${CLUSTER_B_RG}"
    CLUSTER_NAME="${CLUSTER_B_NAME}"
    CONFIG_OUT="${ROOT_DIR}/config-B.json"
    ;;
  *)
    if [[ "${COMMAND}" != "reset" && "${COMMAND}" != "network-fix" ]]; then
      echo "Usage: $0 {join|gpu-stack|validate} {a|b} | $0 {reset|network-fix}" >&2
      exit 1
    fi
    ;;
esac

ensure_helper() {
  if [[ ! -x "${ROOT_DIR}/aks-flex-config" ]]; then
    curl -fsSLo "${ROOT_DIR}/aks-flex-config" https://raw.githubusercontent.com/Azure/AKSFlexNode/main/scripts/aks-flex-config
    chmod +x "${ROOT_DIR}/aks-flex-config"
  fi
}

ensure_kubeconfig() {
  az aks get-credentials --resource-group "${CLUSTER_RG}" --name "${CLUSTER_NAME}" --overwrite-existing >/dev/null
}

prepare_gpu_host_runtime() {
  run_gpu_host_script 'set -eu
    sudo nvidia-smi
    sudo machinectl list | grep -q "^kube1[[:space:]]"
    if ! sudo machinectl shell kube1 /bin/bash -lc "command -v nvidia-smi >/dev/null 2>&1"; then
      sudo machinectl copy-to kube1 /usr/bin/nvidia-smi /usr/bin/nvidia-smi
    fi
    sudo machinectl shell kube1 /bin/bash -lc "
      set -euo pipefail
      install -d /run/nvidia/driver/usr/bin /run/nvidia/driver/usr/lib/x86_64-linux-gnu
      install -m 0755 /usr/bin/nvidia-smi /run/nvidia/driver/usr/bin/nvidia-smi
      find /usr/lib/x86_64-linux-gnu -maxdepth 1 \( -name 'libcuda.so*' -o -name 'libnvidia*.so*' \) -exec cp -a -t /run/nvidia/driver/usr/lib/x86_64-linux-gnu {} +
      nvidia-smi
      /run/nvidia/driver/usr/bin/nvidia-smi
      test -e /dev/nvidia0
      ldconfig -p | grep -q libcuda.so.1
      ldconfig -p | grep -q libnvidia-ml.so.1
      test -x /run/nvidia/driver/usr/bin/nvidia-smi
      test -e /run/nvidia/driver/usr/lib/x86_64-linux-gnu/libcuda.so.1
      test -e /run/nvidia/driver/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
      test ! -e /etc/cni/net.d/15-azure.conflist
    "
  '
}

ensure_flexnode_kube_proxy() {
  local server_url api_host
  if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
    server_url="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    api_host="${server_url#https://}"
    api_host="${api_host%%:*}"

    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: aks-flex-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-proxy-flexnode
  namespace: aks-flex-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-kube-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-proxier
subjects:
- kind: ServiceAccount
  name: kube-proxy-flexnode
  namespace: aks-flex-system
EOF

    kubectl -n kube-system get ds kube-proxy -o json | jq --arg apiHost "${api_host}" '
      del(
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.managedFields,
        .metadata.resourceVersion,
        .metadata.uid,
        .status
      )
      | .metadata.name = "kube-proxy-flexnode"
      | .metadata.namespace = "aks-flex-system"
      | .metadata.labels["aks-flex-node/component"] = "kube-proxy"
      | .spec.selector.matchLabels.component = "kube-proxy-flexnode"
      | .spec.template.metadata.labels.component = "kube-proxy-flexnode"
      | .spec.template.metadata.labels["aks-flex-node/component"] = "kube-proxy"
      | .spec.template.spec.serviceAccountName = "kube-proxy-flexnode"
      | .spec.template.spec.nodeName = null
      | .spec.template.spec.containers |= map(
          if .name == "kube-proxy" then
            .env = ((.env // [])
              | map(select(.name != "KUBERNETES_SERVICE_HOST" and .name != "KUBERNETES_SERVICE_PORT"))
              + [
                  {"name":"KUBERNETES_SERVICE_HOST","value":$apiHost},
                  {"name":"KUBERNETES_SERVICE_PORT","value":"443"}
                ]
            )
          else
            .
          end
        )
      | .spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions |= (
          map(select(.key != "kubernetes.azure.com/cluster"))
          + [{"key":"kubernetes.azure.com/managed","operator":"In","values":["false"]}]
        )
    ' | kubectl apply -f -
    kubectl -n aks-flex-system rollout status ds/kube-proxy-flexnode --timeout=5m
  fi
}

verify_gpu_operator_policy() {
  local driver_enabled
  driver_enabled="$(kubectl get clusterpolicy -o jsonpath='{.items[0].spec.driver.enabled}' 2>/dev/null || true)"
  if [[ "${driver_enabled}" != "false" ]]; then
    echo "GPU Operator driver.enabled must be false for AKSFlexNode preinstalled-driver hosts; got '${driver_enabled}'." >&2
    exit 2
  fi
}

prepare_flex_networking() {
  if [[ "${FLEXNODE_REMAP_DOCKER_BRIDGE:-false}" != "true" ]]; then
    return 0
  fi

  local docker_bridge_bip conflicting_local_cidr script
  docker_bridge_bip="${FLEXNODE_DOCKER_BRIDGE_BIP:-172.31.0.1/16}"
  conflicting_local_cidr="${FLEXNODE_CONFLICTING_LOCAL_CIDR:-172.17.0.0/16}"

  script="$(cat <<EOF
export CONFLICTING_LOCAL_CIDR='${conflicting_local_cidr}'
export DOCKER_BRIDGE_BIP='${docker_bridge_bip}'
EOF
)"
  script+=$'\n'
  script+="$(cat <<'EOF'
set -euo pipefail

configure_docker_bridge() {
  if ! command -v docker >/dev/null 2>&1 && ! systemctl list-unit-files docker.service >/dev/null 2>&1; then
    return 0
  fi

  install -d -m 0755 /etc/docker
  if [[ -s /etc/docker/daemon.json ]] && command -v jq >/dev/null 2>&1; then
    tmp_file="$(mktemp)"
    jq --arg bip "${DOCKER_BRIDGE_BIP}" '.bip = $bip' /etc/docker/daemon.json > "${tmp_file}"
    install -m 0644 "${tmp_file}" /etc/docker/daemon.json
    rm -f "${tmp_file}"
  else
    cp -f /etc/docker/daemon.json /etc/docker/daemon.json.bak 2>/dev/null || true
    printf '{"bip":"%s"}\n' "${DOCKER_BRIDGE_BIP}" >/etc/docker/daemon.json
  fi

  systemctl restart docker 2>/dev/null || true
}

remove_conflicting_docker0() {
  if ip -o route show "${CONFLICTING_LOCAL_CIDR}" 2>/dev/null | grep -qw docker0; then
    ip link delete docker0 2>/dev/null || true
  fi
}

configure_docker_bridge
remove_conflicting_docker0

if machinectl list --no-legend 2>/dev/null | awk '{print $1}' | grep -qx kube1; then
  machinectl shell kube1 /bin/bash -lc "
    set -euo pipefail
    export CONFLICTING_LOCAL_CIDR='${CONFLICTING_LOCAL_CIDR}'
    export DOCKER_BRIDGE_BIP='${DOCKER_BRIDGE_BIP}'
    $(declare -f configure_docker_bridge)
    $(declare -f remove_conflicting_docker0)
    configure_docker_bridge
    remove_conflicting_docker0
  "
fi

if ip -o route show "${CONFLICTING_LOCAL_CIDR}" 2>/dev/null | grep -qw docker0; then
  echo "Host still has ${CONFLICTING_LOCAL_CIDR} routed to docker0." >&2
  exit 2
fi
EOF
)"

  run_gpu_host_root_script "${script}"
}

verify_flex_networking() {
  if [[ "${FLEXNODE_REMAP_DOCKER_BRIDGE:-false}" != "true" ]]; then
    return 0
  fi

  local docker_bridge_bip conflicting_local_cidr script
  docker_bridge_bip="${FLEXNODE_DOCKER_BRIDGE_BIP:-172.31.0.1/16}"
  conflicting_local_cidr="${FLEXNODE_CONFLICTING_LOCAL_CIDR:-172.17.0.0/16}"

  script="$(cat <<EOF
export CONFLICTING_LOCAL_CIDR='${conflicting_local_cidr}'
export DOCKER_BRIDGE_BIP='${docker_bridge_bip}'
EOF
)"
  script+=$'\n'
  script+="$(cat <<'EOF'
set -euo pipefail

if machinectl list --no-legend 2>/dev/null | awk '{print $1}' | grep -qx kube1; then
  machinectl shell kube1 /bin/bash -lc "
    set -euo pipefail
    if ip -o route show '${CONFLICTING_LOCAL_CIDR}' 2>/dev/null | grep -qw docker0; then
      echo 'kube1 still has ${CONFLICTING_LOCAL_CIDR} routed to docker0.' >&2
      exit 2
    fi
    ip route get 172.17.0.1 || true
  "
fi
EOF
)"

  run_gpu_host_root_script "${script}"
}

generate_bootstrap_mi_config() {
  local subscription_id token_id token_secret token expiration server_url ca_cert_data cluster_fqdn resource_id location kubernetes_version dns_service_ip
  subscription_id="$(az account show --query id -o tsv)"
  token_id="$(openssl rand -hex 3)"
  BOOTSTRAP_TOKEN_ID="${token_id}"
  token_secret="$(openssl rand -hex 8)"
  token="${token_id}.${token_secret}"
  expiration="$(date -u -d '+24 hours' '+%Y-%m-%dT%H:%M:%SZ')"
  resource_id="$(az aks show --resource-group "${CLUSTER_RG}" --name "${CLUSTER_NAME}" --query id -o tsv)"
  location="$(az aks show --resource-group "${CLUSTER_RG}" --name "${CLUSTER_NAME}" --query location -o tsv)"
  kubernetes_version="$(az aks show --resource-group "${CLUSTER_RG}" --name "${CLUSTER_NAME}" --query 'currentKubernetesVersion || kubernetesVersion' -o tsv)"
  dns_service_ip="$(az aks show --resource-group "${CLUSTER_RG}" --name "${CLUSTER_NAME}" --query networkProfile.dnsServiceIp -o tsv)"
  server_url="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  ca_cert_data="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  cluster_fqdn="${server_url#https://}"

  kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-bootstrapper
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-auto-approve-csr
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: aks-flex-node-daemon-csr-approver
rules:
- apiGroups:
  - certificates.k8s.io
  resources:
  - certificatesigningrequests/approval
  verbs:
  - update
- apiGroups:
  - certificates.k8s.io
  resources:
  - signers
  resourceNames:
  - kubernetes.io/kube-apiserver-client
  verbs:
  - approve
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-daemon-csr-approver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aks-flex-node-daemon-csr-approver
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-role
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
EOF

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${token_id}
  namespace: kube-system
  labels:
    aks-flex-node/e2e-daemon-csr: "true"
type: bootstrap.kubernetes.io/token
stringData:
  description: "AKS Flex Node bootstrap token"
  token-id: "${token_id}"
  token-secret: "${token_secret}"
  expiration: "${expiration}"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers:aks-flex-node"
EOF

  tenant_id="${TENANT_ID:-$(az account show --query tenantId -o tsv)}"

  jq -n \
    --arg subscriptionId "${subscription_id}" \
    --arg tenantId "${tenant_id}" \
    --arg agentPoolName "${AGENT_POOL_NAME}" \
    --arg token "${token}" \
    --arg resourceId "${resource_id}" \
    --arg location "${location}" \
    --arg serverURL "${server_url}" \
    --arg clusterFQDN "${cluster_fqdn}" \
    --arg caCertData "${ca_cert_data}" \
    --arg dnsServiceIP "${dns_service_ip}" \
    --arg kubernetesVersion "${kubernetes_version}" \
    --arg authMode "${FLEXNODE_JOIN_AUTH_MODE:-bootstrap-token}" \
    --arg managedIdentityClientId "${MANAGED_IDENTITY_CLIENT_ID:-}" \
    '(
      {
        azure: {
          subscriptionId: $subscriptionId,
          tenantId: $tenantId,
          resourceManagerEndpoint: "https://management.azure.com",
          targetAgentPoolName: $agentPoolName,
          bootstrapToken: {token: $token},
          arc: {enabled: false},
          targetCluster: {resourceId: $resourceId, location: $location}
        },
        node: {kubelet: {clusterFQDN: $clusterFQDN, serverURL: $serverURL, caCertData: $caCertData}},
        networking: {dnsServiceIP: $dnsServiceIP},
        agent: {logLevel: "info", logDir: "/var/log/aks-flex-node"},
        components: {kubernetes: $kubernetesVersion},
        kubernetes: {version: $kubernetesVersion}
      }
    )
    | if $authMode == "bootstrap-token-managed-identity" then
        .azure.managedIdentity = (if $managedIdentityClientId == "" then {} else {clientId: $managedIdentityClientId} end)
      else
        .
      end' > "${CONFIG_OUT}"
  chmod 600 "${CONFIG_OUT}"
}

approve_flex_daemon_csrs() {
  local requestor pending_csrs
  if [[ -z "${BOOTSTRAP_TOKEN_ID:-}" ]]; then
    return 0
  fi

  requestor="system:bootstrap:${BOOTSTRAP_TOKEN_ID}"
  pending_csrs="$(kubectl get csr -o json | jq -r --arg requestor "${requestor}" '
    .items[]
    | select(.spec.signerName == "kubernetes.io/kube-apiserver-client")
    | select(.spec.username == $requestor)
    | select((.status.conditions // []) | map(.type) | index("Approved") | not)
    | .metadata.name
  ')"
  if [[ -n "${pending_csrs}" ]]; then
    xargs -r kubectl certificate approve <<< "${pending_csrs}"
  fi
}

case "${COMMAND}" in
  join)
    ensure_helper
    ensure_kubeconfig
    if [[ "${FLEXNODE_JOIN_AUTH_MODE:-managed-identity}" == "bootstrap-token" || "${FLEXNODE_JOIN_AUTH_MODE:-managed-identity}" == "bootstrap-token-managed-identity" ]]; then
      generate_bootstrap_mi_config
    elif [[ "${SETUP_BOOTSTRAP_RBAC:-false}" == "true" ]]; then
      "${ROOT_DIR}/aks-flex-config" setup-node-rbac \
        --resource-group "${CLUSTER_RG}" \
        --cluster-name "${CLUSTER_NAME}" \
        --subscription "$(az account show --query id -o tsv)"
      identity_args=()
      if [[ -n "${MANAGED_IDENTITY_CLIENT_ID:-}" ]]; then
        identity_args+=(--username "${MANAGED_IDENTITY_CLIENT_ID}")
      fi
      "${ROOT_DIR}/aks-flex-config" generate-node-config \
        --resource-group "${CLUSTER_RG}" \
        --cluster-name "${CLUSTER_NAME}" \
        --subscription "$(az account show --query id -o tsv)" \
        --agent-pool-name "${AGENT_POOL_NAME}" \
        --identity \
        "${identity_args[@]}" \
        --output "${CONFIG_OUT}"
      tmp_config="$(mktemp)"
      jq '.kubernetes.version = .components.kubernetes' "${CONFIG_OUT}" > "${tmp_config}"
      install -m 0600 "${tmp_config}" "${CONFIG_OUT}"
      rm -f "${tmp_config}"
    fi
    copy_to_gpu_host "${CONFIG_OUT}" "/tmp/aks-flex-node-config.json"
    prepare_flex_networking
    run_gpu_host_script 'set -euo pipefail
      curl -fsSL https://raw.githubusercontent.com/Azure/AKSFlexNode/main/scripts/install.sh | sudo bash -s -- --yes
      sudo install -d -m 0700 /etc/aks-flex-node
      sudo install -m 0600 /tmp/aks-flex-node-config.json /etc/aks-flex-node/config.json
      timeout 15m sudo aks-flex-node start --config /etc/aks-flex-node/config.json
      sudo systemctl is-active aks-flex-node-agent
      sudo nvidia-smi
    '
    approve_flex_daemon_csrs
    ensure_flexnode_kube_proxy
    prepare_flex_networking
    verify_flex_networking
    kubectl get nodes -o wide
    ;;
  gpu-stack)
    ensure_kubeconfig
    prepare_gpu_host_runtime
    ensure_flexnode_kube_proxy
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
    helm repo update >/dev/null
    helm upgrade --install --reset-values --create-namespace -n gpu-operator gpu-operator nvidia/gpu-operator \
      --set driver.enabled="${GPU_OPERATOR_DRIVER_ENABLED:-false}" \
      --set devicePlugin.enabled="${GPU_OPERATOR_DEVICE_PLUGIN_ENABLED:-true}" \
      --set gfd.enabled="${GPU_OPERATOR_GFD_ENABLED:-true}" \
      --set toolkit.enabled="${GPU_OPERATOR_TOOLKIT_ENABLED:-true}" \
      --set hostPaths.driverInstallDir="${GPU_OPERATOR_DRIVER_INSTALL_DIR:-/run/nvidia/driver}"
    verify_gpu_operator_policy
    kubectl -n gpu-operator get pods
    ;;
  validate)
    ensure_kubeconfig
    kubectl get nodes -o wide
    node_name="$(kubectl get nodes -o jsonpath='{range .items[?(@.metadata.labels.nvidia\.com/gpu\.count)]}{.metadata.name}{"\n"}{end}' | head -n 1)"
    if [[ -z "${node_name}" ]]; then
      echo "No node with nvidia.com/gpu.count label found yet." >&2
      exit 2
    fi
    kubectl get node "${node_name}" --show-labels | tr ',' '\n' | grep 'nvidia.com/gpu' || true
    kubectl apply -f "${ROOT_DIR}/gpu-smoke-pod.yaml"
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=10m
    kubectl logs gpu-smoke
    kubectl delete pod gpu-smoke --ignore-not-found
    ;;
  reset)
    run_remote 'sudo aks-flex-node reset || sudo aks-flex-node unbootstrap || true; sudo nvidia-smi'
    ;;
  network-fix)
    prepare_flex_networking
    verify_flex_networking
    ;;
  *)
    echo "Usage: $0 {join|gpu-stack|validate} {a|b} | $0 {reset|network-fix}" >&2
    exit 1
    ;;
esac
