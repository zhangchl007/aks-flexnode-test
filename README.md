# AKS Flex Node GPU Sample

Small sample for attaching an Azure GPU VM to AKS clusters with AKS Flex Node, installing the NVIDIA GPU Operator, and running a GPU smoke pod.

## Files

- `env.example` - sample settings for Azure, AKS, and the GPU host.
- `preflight.sh` - checks required tools, AKS cluster A, GPU quota, and image availability.
- `provision.sh` - creates cluster B and the GPU VM when needed.
- `flexnode.sh` - joins, configures GPU support, validates, or resets the Flex Node host.
- `cleanup.sh` - optional resource group cleanup.

## Quick Start

```bash
cp env.example .env
# Edit .env for your subscription, clusters, GPU VM, SSH key, and TARGET_HOST.

./preflight.sh
./provision.sh

# Join the GPU host to cluster A or B.
./flexnode.sh join a
./flexnode.sh gpu-stack a
./flexnode.sh validate a
```

Switch to cluster B by replacing `a` with `b`:

```bash
./flexnode.sh join b
./flexnode.sh gpu-stack b
./flexnode.sh validate b
```

Reset the GPU host before joining another cluster:

```bash
./flexnode.sh reset
```

## Cleanup

Cleanup is opt-in. Set the flags only for resource groups you want to delete:

```bash
DELETE_GPU_RG=true DELETE_CLUSTER_B_RG=true ./cleanup.sh
```

Cluster A is intentionally preserved by the cleanup script.
