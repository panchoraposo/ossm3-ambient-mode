# Bookinfo on OpenShift Service Mesh 3 (Istio Ambient) — Multi-Cluster Demo

This repository provisions a **two-cluster** OpenShift Service Mesh 3 environment running **Istio Ambient Mode** and deploys the **Bookinfo** sample application on both clusters.

It also installs a **central observability hub** on an ACM cluster (`acm`) so you can use a single Kiali instance with:
- Multi-cluster topology (`east` + `west`)
- Centralized metrics (via promxy fan-out)
- Centralized tracing (Tempo) with Kiali integration

## What gets installed

- **Data clusters (`east`, `west`)**
  - OSSM 3 (Sail operator) — Ambient profile
  - Multi-primary, multi-network configuration (east-west HBONE gateways + `meshNetworks`)
  - `bookinfo` namespace enrolled in ambient
  - **Per-service waypoints** for `productpage`, `reviews`, `ratings`, `details` (L7 telemetry + traces)
  - Bookinfo app + versioned workloads (`reviews-v1/v2/v3`, etc.)
  - Red Hat **Cluster Observability Operator** (installed in `openshift-cluster-observability-operator`)
  - `nfl-wallet` (registers a Helm repository: `https://maximilianopizarro.github.io/NFL-Wallet`)
  - Connectivity Link components in `kuadrant-system` and a `Kuadrant` CR applied from [`kuadrant.yaml`](https://raw.githubusercontent.com/maximilianoPizarro/nfl-wallet-gitops/main/kuadrant.yaml)

- **Hub cluster (`acm`)**
  - OpenShift GitOps (operator + `ArgoCD/openshift-gitops`, with controller resources patched)
  - Grafana Operator (OLM, `grafana-operator` from `community-operators`, channel `v5`)
  - TempoStack (Tempo) for centralized tracing
  - Red Hat build of OpenTelemetry Operator + `OpenTelemetryCollector` (OTLP/HTTP ingest) for trace ingestion from data clusters
  - promxy as a single Prometheus-compatible API for Kiali (fan-out to both clusters)
  - A single **Kiali multi-cluster** instance (reads `east` + `west`)

## Prerequisites

- `oc` CLI installed and logged in to all clusters
- Kubeconfig contexts:
  - `east`
  - `west`
  - `acm`
- Cluster-admin (or equivalent) permissions to create OLM subscriptions, namespaces, RBAC, and mesh resources.

## Local setup (once per machine)

Create a virtual environment (optional) and install dependencies:

```bash
python3 -m venv venv
source venv/bin/activate

python3 -m pip install -r requirements.txt
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

## Inventory

Edit `inventory.yaml` and confirm the contexts match your kubeconfig:
- `east.k8s_context`
- `west.k8s_context`
- `acm.k8s_context`

## Install a single cluster (east only)

If you want to install **everything needed for a standalone demo** on a single cluster (for example `east`), you can use the single-cluster installer.

Pick one of the following approaches:

- Use your **current kubeconfig context** (recommended if you already switched to `east`):

```bash
oc config use-context east
./install.sh
```

- Or explicitly target a context (recommended in CI or if you run multiple installs back-to-back):

```bash
./install.sh -e k8s_context=east
```

This installs GitOps, ODF/Tempo + OTEL, OSSM 3 Ambient, Bookinfo, and Connectivity Link on that cluster.

## Install the full demo

This is the main entrypoint:

```bash
./install-multi-cluster.sh
```

High-level phases:
1. Generate and distribute a shared root CA for the mesh
2. Install OSSM 3 Ambient on `east` and `west`
3. Exchange remote secrets (peering)
4. Configure multi-network (east-west gateway + `meshNetworks`)
5. Install Cluster Observability Operator + Connectivity Link + Kuadrant on `east` and `west`
6. Install GitOps on `acm`
7. Install Grafana Operator on `acm`
8. Deploy Bookinfo + per-service waypoints
9. Install centralized tracing on `acm` and configure exporters on `east`/`west`
10. Install centralized observability on `acm` (promxy + Kiali multi-cluster)

By default, the installer also scales worker MachineSets on `east` and `west` to ensure there are enough worker nodes for pod-heavy components:
- `machineset_target_worker_replicas_total` (default: `2`)

For Single Node OpenShift (SNO) clusters, MachineSets are typically not available. In that case the installer will skip MachineSet scaling, but it will run a pod-capacity preflight to avoid stalling in OLM waits.

If you want to keep `east`/`west` as SNO but still run pod-heavy components (Connectivity Link, Kuadrant, demo apps), you can optionally increase the kubelet `maxPods` limit (this triggers a MachineConfigPool rollout and reboots the node):
- `sno_maxpods_enable` (default: `false`)
- `sno_maxpods_value` (default: `500`)

On SNO, kubelet restarts/rollouts can generate pending `kubelet-serving` CSRs. If they are not approved quickly, `oc logs/exec/debug` may fail with `tls: internal error`. The installer includes an automatic CSR approval step for pending `kubelet-serving` CSRs.

## Generate traffic

```bash
./generate-traffic.sh
```

For a more "demo-friendly" traffic pattern (concurrency + mixed endpoints + bursts):

```bash
./generate-traffic-realistic.sh --workers 20 --interval 1
```

## Viewing the demo

- **Bookinfo**
  - Each cluster exposes `Route/bookinfo-gateway` in namespace `bookinfo`.

- **Kiali (central, on `acm`)**
  - Route `kiali` in namespace `istio-system` on the `acm` cluster.
  - Use the cluster selector to switch between `east` and `west`.

- **Tracing (Ambient-specific note)**
  - In Ambient, L7 traces are produced by **waypoints**.
  - If you click `productpage`, you may not see L7 spans unless you add a waypoint for it.
  - To see consistent traces, use the **Traces** tab on:
    - `productpage-waypoint`
    - `reviews-waypoint`
    - `ratings-waypoint`
    - `details-waypoint`
    - `bookinfo-gateway-istio`

## NFL Wallet demo (Connectivity Link + Kuadrant use cases)

In addition to Bookinfo, this demo supports the **NFL Wallet** sample as an optional workload to showcase **Connectivity Link / Kuadrant** capabilities (Gateway API, policy enforcement, etc.).

### What the installer does

On **each data cluster** (`east`, `west`) the playbook creates a `HelmChartRepository` named `nfl-wallet` (OpenShift Helm integration), pointing to:
- `https://maximilianopizarro.github.io/NFL-Wallet`

This repository can then be used to install NFL Wallet charts from the OpenShift Console, and to demonstrate Kuadrant/Connectivity Link features on top of those workloads.

### Verify it was installed

```bash
oc --context east get helmchartrepositories.helm.openshift.io nfl-wallet -o yaml
oc --context west get helmchartrepositories.helm.openshift.io nfl-wallet -o yaml
```

### Deploy the application (manual step)

The installer registers the repository, but **it does not deploy the NFL Wallet workloads by default**. Deploy the charts using the OpenShift Console (Helm) or your preferred GitOps workflow.

## Troubleshooting

### Kiali shows no traces

- Ensure traffic is being generated.
- Ensure Tempo is receiving spans.
- In this demo, Kiali queries Tempo via the **Jaeger Query API** exposed by Tempo (Tempo query-frontend `:16686`).

### Intermittent 503 / timeouts in Bookinfo (Ambient dataplane hiccups)

If you see intermittent upstream timeouts, restarting `istio-cni` and `ztunnel` on the affected cluster usually recovers the dataplane:

```bash
oc --context west -n istio-cni delete pod -l k8s-app=istio-cni-node
oc --context west -n ztunnel delete pod -l app=ztunnel
```

Then wait for pods to become Ready.

