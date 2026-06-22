#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy env.example to .env and adjust values." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

if ! az group show --name "${CLUSTER_B_RG}" >/dev/null 2>&1; then
  az group create --name "${CLUSTER_B_RG}" --location "${LOCATION_AKS}" -o none
fi

if ! az aks show --resource-group "${CLUSTER_B_RG}" --name "${CLUSTER_B_NAME}" >/dev/null 2>&1; then
  az aks create \
    --resource-group "${CLUSTER_B_RG}" \
    --name "${CLUSTER_B_NAME}" \
    --location "${LOCATION_AKS}" \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --node-count "${CLUSTER_B_NODE_COUNT}" \
    --node-vm-size "${CLUSTER_B_NODE_SIZE}" \
    --network-plugin azure \
    --service-cidr "${CLUSTER_B_SERVICE_CIDR}" \
    --dns-service-ip "${CLUSTER_B_DNS_SERVICE_IP}" \
    --generate-ssh-keys
else
  echo "Cluster B already exists: ${CLUSTER_B_RG}/${CLUSTER_B_NAME}"
fi

if [[ "${PROVISION_GPU_VM:-true}" != "true" ]]; then
  echo "Skipping GPU VM provisioning because PROVISION_GPU_VM is not true."
  exit 0
fi

"${ROOT_DIR}/preflight.sh"

if ! az group show --name "${GPU_RG}" >/dev/null 2>&1; then
  az group create --name "${GPU_RG}" --location "${LOCATION_GPU}" -o none
fi

if ! az vm show --resource-group "${GPU_RG}" --name "${GPU_VM_NAME}" >/dev/null 2>&1; then
  vm_priority_args=()
  if [[ "${USE_SPOT_GPU_VM:-false}" == "true" ]]; then
    vm_priority_args+=(--priority Spot --eviction-policy "${SPOT_EVICTION_POLICY:-Delete}" --max-price "${SPOT_MAX_PRICE:--1}")
  fi
  az vm create \
    --resource-group "${GPU_RG}" \
    --name "${GPU_VM_NAME}" \
    --location "${LOCATION_GPU}" \
    --image "${GPU_IMAGE}" \
    --size "${GPU_VM_SIZE}" \
    --admin-username "${GPU_ADMIN_USER}" \
    --ssh-key-values "${GPU_SSH_KEY}" \
    --assign-identity \
    --public-ip-sku Standard \
    "${vm_priority_args[@]}"
else
  echo "GPU VM already exists: ${GPU_RG}/${GPU_VM_NAME}"
fi

principal_id="$(az vm show --resource-group "${GPU_RG}" --name "${GPU_VM_NAME}" --query identity.principalId -o tsv)"
cluster_a_id="$(az aks show --resource-group "${CLUSTER_A_RG}" --name "${CLUSTER_A_NAME}" --query id -o tsv)"
cluster_b_id="$(az aks show --resource-group "${CLUSTER_B_RG}" --name "${CLUSTER_B_NAME}" --query id -o tsv)"

for scope in "${cluster_a_id}" "${cluster_b_id}"; do
  az role assignment create --assignee-object-id "${principal_id}" --assignee-principal-type ServicePrincipal --role Reader --scope "${scope}" >/dev/null || true
  az role assignment create --assignee-object-id "${principal_id}" --assignee-principal-type ServicePrincipal --role "Azure Kubernetes Service Cluster User Role" --scope "${scope}" >/dev/null || true
done

public_ip="$(az vm show --show-details --resource-group "${GPU_RG}" --name "${GPU_VM_NAME}" --query publicIps -o tsv)"
echo "GPU VM public IP: ${public_ip}"
echo "Update TARGET_HOST in .env to: ${GPU_ADMIN_USER}@${public_ip}"
