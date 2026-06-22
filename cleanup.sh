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

if [[ "${DELETE_GPU_RG:-false}" == "true" ]]; then
  az group delete --name "${GPU_RG}" --yes --no-wait
else
  echo "Skipping GPU resource group deletion. Set DELETE_GPU_RG=true to delete ${GPU_RG}."
fi

if [[ "${DELETE_CLUSTER_B_RG:-false}" == "true" ]]; then
  az group delete --name "${CLUSTER_B_RG}" --yes --no-wait
else
  echo "Skipping cluster B resource group deletion. Set DELETE_CLUSTER_B_RG=true to delete ${CLUSTER_B_RG}."
fi

echo "aks-storage-test is intentionally preserved."
