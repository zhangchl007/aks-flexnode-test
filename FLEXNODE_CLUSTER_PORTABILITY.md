# AKS FlexNode GPU Cluster Portability Runbook

This document records the tested flow for moving one GPU FlexNode host between two AKS clusters, then outlines how to automate the remove and rejoin workflow later with Go.

Do not commit generated FlexNode configs. `config-A.json` and `config-B.json` contain bootstrap material and are intentionally ignored by `.gitignore`.

## Official References

- AKS Flex Node repository and quickstart: https://github.com/Azure/AKSFlexNode
- AKS Flex Node installation script: https://raw.githubusercontent.com/Azure/AKSFlexNode/main/scripts/install.sh
- AKS Flex Node joining guide: https://github.com/Azure/AKSFlexNode/blob/main/docs/usages/joining-nodes.md
- AKS Flex Node operations guide: https://github.com/Azure/AKSFlexNode/blob/main/docs/usages/operations.md
- AKS Flex Node configuration guide: https://github.com/Azure/AKSFlexNode/blob/main/docs/usages/configuration.md
- AKS Flex Config helper guide: https://github.com/Azure/AKSFlexNode/blob/main/docs/usages/aks-flex-config.md
- GPU Flex Node lab: https://github.com/Azure/AKSFlexNode/blob/main/docs/labs/gpu-node-setup.md

## Tested Environment

| Item | Cluster A | Cluster B |
| --- | --- | --- |
| AKS cluster | `aks-storage-test` | `aksflex-gpu-test-b` |
| Resource group | `aks-test-rg` | `aksflex-gpu-test-eastus2-rg` |
| Region | `westus3` | `eastus2` |
| Kubernetes version | `1.33.10` | `1.34.8` |
| Network plugin | Azure CNI | Azure CNI |
| Service CIDR | `172.17.0.0/16` | `10.200.0.0/16` |
| DNS service IP | `172.17.0.10` | `10.200.0.10` |

GPU host:

- Hostname and Kubernetes node name: `aksflexgpu01`
- Host resource group: `aksflex-gpu-host-rg`
- Host VM size: `Standard_NC4as_T4_v3`
- Spot VM: enabled with eviction policy `Delete`
- GPU: NVIDIA Tesla T4
- Host image: `microsoft-dsvm:ubuntu-hpc:2204:latest`
- Current tested final state: joined to cluster B, `Ready`, `nvidia.com/gpu=1`, CUDA VectorAdd `Test PASSED`

## Implementation Files

| File | Purpose |
| --- | --- |
| `env.example` | Safe template for cluster, GPU host, Spot VM, AKSFlexNode, and GPU Operator settings. |
| `.env` | Local runtime values. Keep local only if it contains sensitive or environment-specific data. |
| `preflight.sh` | Validates local tools, cluster A access, GPU SKU availability, Spot quota behavior, and image availability. |
| `provision.sh` | Creates or reuses cluster B and the Spot GPU VM, then assigns the GPU VM identity reader/user permissions on both clusters. |
| `flexnode.sh` | Main operational script for `join`, `gpu-stack`, `validate`, and `reset`. |
| `gpu-smoke-pod.yaml` | CUDA VectorAdd smoke workload requesting `nvidia.com/gpu: 1`. |
| `.gitignore` | Prevents committing `config-A.json` and `config-B.json`. |

## Core Script Behavior

`flexnode.sh` uses the cluster alias `a` or `b` to select the target AKS cluster and generated config output:

```bash
./flexnode.sh join a
./flexnode.sh gpu-stack a
./flexnode.sh validate a

./flexnode.sh reset

./flexnode.sh join b
./flexnode.sh gpu-stack b
./flexnode.sh validate b
```

Important implementation details:

- Auth mode is `bootstrap-token`.
- `config-A.json` and `config-B.json` are generated per target cluster and copied to the host as `/etc/aks-flex-node/config.json`.
- The official installer is used on the target host:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Azure/AKSFlexNode/main/scripts/install.sh | sudo bash -s -- --yes
  ```

- The host starts AKS Flex Node with:

  ```bash
  sudo aks-flex-node start --config /etc/aks-flex-node/config.json
  ```

- The long-running host service is `aks-flex-node-agent`.
- The worker runtime is a systemd-nspawn machine named `kube1`.
- The script approves only the current bootstrap token's pending daemon CSR for signer `kubernetes.io/kube-apiserver-client`.
- The script creates a FlexNode-only kube-proxy DaemonSet in namespace `aks-flex-system`, targeting `kubernetes.azure.com/managed=false`.
- GPU Operator is installed with the NVIDIA driver disabled because the driver is already installed on the host image.

## Progress Summary

### Cluster A Join

Cluster A was successfully joined and validated before the node was removed for the B rejoin test.

What was proven:

- `aksflexgpu01` could join `aks-storage-test` as a FlexNode.
- The node reached `Ready`.
- The GPU stack exposed `nvidia.com/gpu=1`.
- CUDA VectorAdd passed.
- `BRIDGE_BIP=172.31.0.1/16` was not the root cause of earlier cluster A issues and was removed from the scripts.
- VNet peering or any broader environment connectivity should remain outside these FlexNode scripts.

Cluster A notes:

- Service CIDR is `172.17.0.0/16`.
- DNS service IP is `172.17.0.10`.
- The service CIDR must be written into generated config as `networking.dnsServiceIP` through AKS metadata.
- The Kubernetes service VIP for cluster A is `172.17.0.1`.
- FlexNode kube-proxy was required so workloads on the FlexNode could use ClusterIP services.

### Rejoin To Cluster B

The host was reset after removal from cluster A and rejoined to cluster B.

Final verified cluster B state:

- `aksflexgpu01` is `Ready` in `aksflex-gpu-test-b`.
- Internal IP is `10.0.0.4`.
- Kubelet version is `v1.34.8`.
- Container runtime is `containerd://2.0.4`.
- GPU capacity is `nvidia.com/gpu: 1`.
- GPU allocatable is `nvidia.com/gpu: 1`.
- GPU Operator pods are running.
- `aks-flex-system/kube-proxy-flexnode` is running.
- CUDA VectorAdd smoke test completed and local container logs showed `Test PASSED`.

Cluster B notes:

- Service CIDR is `10.200.0.0/16`.
- DNS service IP is `10.200.0.10`.
- The Kubernetes service VIP for cluster B is `10.200.0.1`.
- Service VIP routing from inside `kube1` was verified with `curl -k https://10.200.0.1:443/version`, which returned the expected Kubernetes API `401 Unauthorized` response.
- `kubectl logs` through the API server failed for the FlexNode because API-server-to-kubelet proxying to `10.0.0.4:10250` returned `500`. The workload still succeeded; logs were collected locally with `crictl` inside `kube1`.
- The original managed system node in cluster B was `NotReady` during the final snapshot. That did not block the FlexNode GPU workload validation, but it should be tracked separately if cluster B is reused.

## Detailed Remove And Rejoin Steps

### 1. Confirm Current Cluster Ownership

Set kubeconfig to the source cluster and confirm the FlexNode exists:

```bash
az aks get-credentials -g <source-rg> -n <source-cluster> --overwrite-existing
kubectl get node aksflexgpu01 -o wide
kubectl get node aksflexgpu01 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Expected result:

- The node exists in exactly one cluster.
- The node is `Ready` before scheduled removal, unless the operation is a recovery flow.

### 2. Cordon And Drain The FlexNode

For planned moves, stop new scheduling and evict workloads first:

```bash
kubectl cordon aksflexgpu01
kubectl drain aksflexgpu01 --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

Notes:

- DaemonSet pods such as kube-proxy and GPU Operator components are ignored by drain.
- Add workload-specific PodDisruptionBudget handling before production automation.
- The official design notes that AKS/RP owns workload disruption decisions because drain needs cluster-wide scheduling context. For this lab, we perform explicit `kubectl cordon` and `kubectl drain`.

### 3. Reset The Host Runtime

Run the local reset against the GPU host:

```bash
./flexnode.sh reset
```

Manual equivalent on the host:

```bash
sudo aks-flex-node reset || sudo aks-flex-node unbootstrap || true
sudo systemctl is-active aks-flex-node-agent || true
sudo machinectl list
```

Expected result:

- `aks-flex-node-agent` is inactive or removed.
- `machinectl list` shows no active `kube1` machine.
- NVIDIA driver on the host still works with `nvidia-smi`.

### 4. Delete The Source Cluster Node Object

The official operations guide separates host reset or uninstall from Kubernetes node cleanup. Delete the stale node object from the source cluster:

```bash
az aks get-credentials -g <source-rg> -n <source-cluster> --overwrite-existing
kubectl delete node aksflexgpu01 --ignore-not-found
kubectl get node aksflexgpu01
```

Expected result:

- The source cluster no longer has a `Node` object named `aksflexgpu01`.

### 5. Join The Target Cluster

Run the join flow for the target cluster alias:

```bash
./flexnode.sh join b
```

For cluster A use:

```bash
./flexnode.sh join a
```

The script performs these actions:

1. Gets AKS credentials for the selected cluster.
2. Creates bootstrap RBAC for `system:bootstrappers:aks-flex-node`.
3. Creates a 24-hour bootstrap token Secret in `kube-system`.
4. Generates a per-cluster config file with API server URL, CA data, Kubernetes version, target cluster ARM ID, and DNS service IP.
5. Copies the generated config to the GPU host.
6. Installs or updates `aks-flex-node` using the official installer.
7. Writes `/etc/aks-flex-node/config.json` with mode `0600`.
8. Runs `aks-flex-node start`.
9. Approves the current token's pending daemon CSR if needed.
10. Installs or updates FlexNode-only kube-proxy.
11. Prints `kubectl get nodes -o wide`.

Validation commands:

```bash
kubectl get nodes -o wide
kubectl get csr --sort-by=.metadata.creationTimestamp | tail -30
ssh "$TARGET_HOST" 'sudo systemctl is-active aks-flex-node-agent; sudo machinectl list'
```

Expected result:

- New kubelet CSR is `Approved,Issued`.
- New daemon CSR for the current bootstrap token is `Approved,Issued`.
- The node appears in the target cluster as `Ready`.
- Do not bulk approve old stale CSRs from previous tokens.

### 6. Reconcile The GPU Stack

Run:

```bash
./flexnode.sh gpu-stack b
```

For cluster A use:

```bash
./flexnode.sh gpu-stack a
```

The script performs these actions:

1. Confirms the host NVIDIA driver works with `nvidia-smi`.
2. Confirms `kube1` exists.
3. Copies `nvidia-smi` into `kube1` if missing.
4. Populates `/run/nvidia/driver/usr/bin` and `/run/nvidia/driver/usr/lib/x86_64-linux-gnu` inside `kube1`.
5. Confirms `/dev/nvidia0`, `libcuda.so.1`, and `libnvidia-ml.so.1` exist.
6. Ensures FlexNode kube-proxy is running.
7. Installs or upgrades NVIDIA GPU Operator with:

   ```text
   driver.enabled=false
   devicePlugin.enabled=true
   gfd.enabled=true
   toolkit.enabled=false
   hostPaths.driverInstallDir=/run/nvidia/driver
   ```

Expected result:

- `kubectl -n gpu-operator get pods` shows device plugin, GFD, DCGM exporter, and validator converging.
- `kubectl get node aksflexgpu01 -o jsonpath='{.status.capacity.nvidia\.com/gpu}{"\n"}'` returns `1`.

### 7. Validate GPU Workload

Run:

```bash
./flexnode.sh validate b
```

Manual validation commands:

```bash
kubectl get node aksflexgpu01 -o json | jq '{ready:[.status.conditions[]|select(.type=="Ready")][0].status, gpu:.status.capacity["nvidia.com/gpu"], allocatableGpu:.status.allocatable["nvidia.com/gpu"]}'
kubectl apply -f gpu-smoke-pod.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=10m
kubectl get pod gpu-smoke -o wide
```

If `kubectl logs gpu-smoke` fails with API-server-to-kubelet proxy errors, collect logs locally from the FlexNode host:

```bash
ssh "$TARGET_HOST" 'sudo machinectl shell kube1 /bin/bash -lc "crictl ps -a --name cuda-vectoradd; for id in $(crictl ps -a --name cuda-vectoradd -q); do crictl logs $id; done"'
```

Expected result:

```text
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
Done
```

Clean up:

```bash
kubectl delete pod gpu-smoke --ignore-not-found
```

## Important Notes

### Service CIDR And DNS Service IP

Each AKS cluster has its own service CIDR and DNS service IP. FlexNode config must match the target cluster:

- Cluster A: service CIDR `172.17.0.0/16`, DNS service IP `172.17.0.10`, Kubernetes service VIP `172.17.0.1`.
- Cluster B: service CIDR `10.200.0.0/16`, DNS service IP `10.200.0.10`, Kubernetes service VIP `10.200.0.1`.

The FlexNode config stores the DNS service IP in `networking.dnsServiceIP`. The Kubernetes service VIP is programmed by kube-proxy from cluster service data.

### FlexNode Kube-Proxy

The built-in AKS kube-proxy DaemonSet is AKS-managed. Editing it directly is not durable. This repo uses a separate DaemonSet:

- Namespace: `aks-flex-system`
- DaemonSet: `kube-proxy-flexnode`
- Target selector: `kubernetes.azure.com/managed=false`
- Service account: `kube-proxy-flexnode`
- RBAC: `system:node-proxier`

This lets pods on the FlexNode resolve ClusterIP services such as the Kubernetes API service VIP.

### Bootstrap CSRs

The join creates two CSR patterns:

- Kubelet client CSR with signer `kubernetes.io/kube-apiserver-client-kubelet`.
- Flex daemon client CSR with signer `kubernetes.io/kube-apiserver-client`.

Only approve the CSR for the current bootstrap token. Old Pending CSRs from earlier tokens should remain untouched unless you can prove they are part of the active run.

### GPU Runtime In `kube1`

AKS FlexNode runs kubelet and containerd inside systemd-nspawn. The host may have `nvidia-smi`, but the recreated `kube1` machine also needs:

- `/usr/bin/nvidia-smi`
- `/run/nvidia/driver/usr/bin/nvidia-smi`
- `/run/nvidia/driver/usr/lib/x86_64-linux-gnu/libcuda.so.1`
- `/run/nvidia/driver/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1`
- `/dev/nvidia0`

After every reset and rejoin, run `./flexnode.sh gpu-stack <a|b>` before GPU validation.

### Confidential Files

Never commit generated FlexNode configs:

```text
config-A.json
config-B.json
```

They contain bootstrap token material and cluster metadata. They are local artifacts only.

## Official Limitations And Caveats

These are based on the official AKS FlexNode README, usage, operations, configuration, design, and GPU lab docs.

1. AKS FlexNode is alpha software.
2. The target host must be Linux with systemd. The installer officially supports Linux and is tested on Ubuntu 22.04 LTS and Ubuntu 24.04 LTS.
3. Host-side install and start operations require root because AKS FlexNode installs packages, writes system config, manages systemd units, manages nspawn machines, and starts Kubernetes runtime services.
4. The host must be able to reach the AKS API server over outbound HTTPS.
5. Private AKS clusters require the command runner and FlexNode host to resolve and reach the private API endpoint.
6. Network ranges must not overlap across the AKS VNet, Flex VM VNet, pod network, service CIDR, and any connected networks.
7. A FlexNode runs the Kubernetes worker inside local systemd-nspawn machines such as `kube1` and `kube2`; automation must treat the host runtime and the Kubernetes `Node` object as separate state surfaces.
8. Reset or uninstall on the host does not automatically remove the Kubernetes `Node` object. Delete the node object from the source cluster separately unless a future AKS RP lifecycle signal owns it.
9. AKS FlexNode supports multiple auth modes, but the config must not enable conflicting Azure auth methods. Bootstrap token can be combined with an Azure auth method for separate kubelet bootstrap and ARM registration, but only one Azure auth method can be enabled at a time.
10. Bootstrap token mode requires the config to include the Kubernetes API server URL and CA data because the host does not fetch cluster connection data through Azure credentials during join.
11. Service principal auth stores static credentials and requires careful secret storage and rotation.
12. AKS FlexNode does not install the NVIDIA kernel driver. The GPU host image must already include a working driver.
13. AKS managed GPU node pool images are not a reusable host-image contract for FlexNode because AKS managed GPU pools install drivers at boot through the AKS-managed bootstrap path.
14. AKS FlexNode does not install GPU Operator, NVIDIA Device Plugin, GPU Feature Discovery, or the optional NVIDIA DRA driver. Those are manual cluster components.
15. GPU Operator must be configured with `driver.enabled=false` when the driver comes from the host image.
16. Image, driver, kernel, containerd, and GPU Operator versions are part of the GPU node contract. Record them for every validation run.
17. If workloads use Kubernetes Dynamic Resource Allocation, install and validate the NVIDIA DRA driver separately. Legacy workloads requesting `nvidia.com/gpu` need the classic device plugin capacity path.
18. Workload disruption decisions such as cordon and drain are not owned by the FlexNode agent; scheduled movement automation must perform or coordinate them explicitly.
19. The AKS RP lifecycle integration and production machine resource flows are still evolving. Current lab and E2E flows use direct host bootstrap and local reconciliation.
20. API-server-to-kubelet operations such as `kubectl logs`, `exec`, and `port-forward` may require network reachability from the AKS control plane or proxy path to the FlexNode kubelet address. In this test, `kubectl logs` failed through the API server, but direct local `crictl logs` inside `kube1` succeeded.
21. Azure Spot VMs can be evicted. Scheduled portability automation must assume the GPU host can disappear and must make reset/rejoin idempotent.

## Future Go Scheduler Design

The future Go implementation should treat cluster movement as a serialized state machine. One host should not be moved by two schedulers at the same time.

Suggested state machine:

```text
Idle
  -> SourceObserved
  -> CordonRequested
  -> Drained
  -> HostReset
  -> SourceNodeDeleted
  -> TargetConfigGenerated
  -> TargetJoinStarted
  -> TargetCSRsApproved
  -> TargetReady
  -> GpuStackReady
  -> SmokeValidated
  -> Complete
```

Required Go modules or clients:

- Kubernetes `client-go` for nodes, cordon/drain, CSRs, DaemonSets, pods, and smoke validation.
- Azure SDK for Go or Azure CLI wrapper for AKS metadata and credentials, if direct SDK auth is not ready.
- SSH client for host commands, with Azure VM Run Command as a bounded fallback.
- Helm SDK or declarative chart runner for GPU Operator, or call Helm as an external command with strict timeouts.
- Persistent state store for operation locks, last successful target cluster, active operation ID, and failure recovery.

Automation rules:

- Use one operation lock per physical host.
- Never move a node unless the source cluster and target cluster are explicit.
- Never approve all pending CSRs. Approve only CSRs tied to the current bootstrap token or expected node identity.
- Treat generated configs as secrets. Write them with mode `0600`, never log token values, and delete or rotate after use.
- Verify service CIDR and DNS service IP from the target AKS cluster before writing config.
- Run `gpu-stack` after every fresh join because `kube1` can be recreated.
- Consider `kubectl logs` optional for FlexNode smoke validation; fall back to host-local `crictl logs` when kubelet proxying is unavailable.
- Add retries around Spot VM capacity, host SSH, Azure Run Command, CSR creation, and GPU Operator convergence.
- Emit structured events for each state transition.
- Store enough evidence for audit: source cluster, target cluster, node name, host ID, Kubernetes version, service CIDR, DNS service IP, GPU capacity, smoke result, timestamps, and operation ID.

## Quick Command Reference

Join cluster A:

```bash
./flexnode.sh join a
./flexnode.sh gpu-stack a
./flexnode.sh validate a
```

Move from cluster A to cluster B:

```bash
az aks get-credentials -g aks-test-rg -n aks-storage-test --overwrite-existing
kubectl cordon aksflexgpu01
kubectl drain aksflexgpu01 --ignore-daemonsets --delete-emptydir-data --timeout=10m
./flexnode.sh reset
kubectl delete node aksflexgpu01 --ignore-not-found

az aks get-credentials -g aksflex-gpu-test-eastus2-rg -n aksflex-gpu-test-b --overwrite-existing
./flexnode.sh join b
./flexnode.sh gpu-stack b
./flexnode.sh validate b
```

Final checks:

```bash
kubectl get nodes -o wide
kubectl get node aksflexgpu01 -o json | jq '{ready:[.status.conditions[]|select(.type=="Ready")][0].status, gpu:.status.capacity["nvidia.com/gpu"], allocatableGpu:.status.allocatable["nvidia.com/gpu"]}'
kubectl -n gpu-operator get pods -o wide
kubectl -n aks-flex-system get pods -o wide
```