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
  - **Per-service waypoints** for `reviews`, `ratings`, `details` (L7 telemetry + traces)
  - Bookinfo app + versioned workloads (`reviews-v1/v2/v3`, etc.)
  - Red Hat **Cluster Observability Operator** (installed in `openshift-cluster-observability-operator`)
  - Connectivity Link components in `kuadrant-system` and a `Kuadrant` CR applied from [`kuadrant.yaml`](https://raw.githubusercontent.com/maximilianoPizarro/nfl-wallet-gitops/main/kuadrant.yaml)

- **Hub cluster (`acm`)**
  - OpenShift GitOps (operator + `ArgoCD/openshift-gitops`, with controller resources patched)
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
7. Deploy Bookinfo + per-service waypoints
8. Install centralized tracing on `acm` and configure exporters on `east`/`west`
9. Install centralized observability on `acm` (promxy + Kiali multi-cluster)

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
    - `reviews-waypoint`
    - `ratings-waypoint`
    - `details-waypoint`
    - `bookinfo-gateway-istio`

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

