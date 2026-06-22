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

required=(az kubectl helm curl ssh scp)
for bin in "${required[@]}"; do
  command -v "${bin}" >/dev/null || { echo "Missing required command: ${bin}" >&2; exit 1; }
done

if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "${SUBSCRIPTION_ID}"
fi

active_sub="$(az account show --query id -o tsv)"
echo "Active subscription: ${active_sub}"

echo "Existing cluster A: ${CLUSTER_A_RG}/${CLUSTER_A_NAME}"
az aks show \
  --resource-group "${CLUSTER_A_RG}" \
  --name "${CLUSTER_A_NAME}" \
  --query '{name:name,resourceGroup:resourceGroup,location:location,kubernetesVersion:kubernetesVersion,fqdn:fqdn,privateFqdn:privateFqdn,networkPlugin:networkProfile.networkPlugin,networkPluginMode:networkProfile.networkPluginMode}' \
  -o table

echo "Checking GPU quota for ${GPU_VM_SIZE} in ${LOCATION_GPU}"
vm_cores="$(az vm list-sizes --location "${LOCATION_GPU}" --query "[?name=='${GPU_VM_SIZE}'].numberOfCores | [0]" -o tsv)"
if [[ -z "${vm_cores}" ]]; then
  echo "GPU VM size ${GPU_VM_SIZE} not found in ${LOCATION_GPU}." >&2
  exit 2
fi

if [[ "${USE_SPOT_GPU_VM:-false}" == "true" ]]; then
  echo "Using Azure Spot VM for GPU host. Spot quota is separate from regular VM quota."
  if [[ -n "${SPOT_GPU_QUOTA_LOCAL_NAME:-}" ]]; then
    family_limit="$(az vm list-usage --location "${LOCATION_GPU}" --query "[?localName=='${SPOT_GPU_QUOTA_LOCAL_NAME}'].limit | [0]" -o tsv)"
    family_current="$(az vm list-usage --location "${LOCATION_GPU}" --query "[?localName=='${SPOT_GPU_QUOTA_LOCAL_NAME}'].currentValue | [0]" -o tsv)"
    quota_label="${SPOT_GPU_QUOTA_LOCAL_NAME}"
  else
    echo "SPOT_GPU_QUOTA_LOCAL_NAME is empty; skipping quota headroom check and letting az vm create validate Spot quota/capacity."
    family_limit="${vm_cores}"
    family_current="0"
    quota_label="Spot quota/capacity at allocation time"
  fi
else
  family_limit="$(az vm list-usage --location "${LOCATION_GPU}" --query "[?localName=='${GPU_QUOTA_LOCAL_NAME}'].limit | [0]" -o tsv)"
  family_current="$(az vm list-usage --location "${LOCATION_GPU}" --query "[?localName=='${GPU_QUOTA_LOCAL_NAME}'].currentValue | [0]" -o tsv)"
  quota_label="${GPU_QUOTA_LOCAL_NAME}"
fi

if [[ -z "${family_limit}" || -z "${family_current}" || -z "${vm_cores}" ]]; then
  echo "Could not determine quota for ${GPU_VM_SIZE} (${quota_label}) in ${LOCATION_GPU}." >&2
  exit 4
fi

available=$((family_limit - family_current))
if (( available < vm_cores )); then
  echo "Insufficient GPU quota for ${GPU_VM_SIZE} in ${LOCATION_GPU}: need ${vm_cores}, available ${available} in ${quota_label}." >&2
  exit 5
fi

echo "Checking Ubuntu HPC image ${GPU_IMAGE} in ${LOCATION_GPU}"
az vm image show --location "${LOCATION_GPU}" --urn "${GPU_IMAGE}" --query '{urn:urn,version:version}' -o table

echo "Preflight passed."
