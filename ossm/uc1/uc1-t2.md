# UC1-T2: Deploying OSSM 3.2 in Ambient Mode

## Objective

Verify that Istio is deployed with **ambient mode** enabled on both clusters. Confirm the key ambient components (ztunnel, istiod, IstioCNI) are running, and prove the sidecarless architecture by showing application pods have **no istio-proxy container** injected.

## Prerequisites

- Clusters accessible with contexts `east`, `west`
- OSSM 3.2 operator installed (verified in UC1-T1)
- bookinfo application deployed in namespace `bookinfo`

## Quick Run

```bash
./ossm/uc1-t2-verify.sh
```

## Manual Steps

### 1. Confirm Istio is deployed with ambient profile

```bash
oc --context east get istio default -n istio-system -o jsonpath='{.spec.profile}'
oc --context west get istio default -n istio-system -o jsonpath='{.spec.profile}'
```

Expected: `ambient` on both clusters.

### 2. Verify IstioCNI (required for ambient)

```bash
oc --context east get istiocni -A
oc --context west get istiocni -A
```

Expected: `STATUS: Healthy`, `VERSION: v1.27.x`.

### 3. Verify ztunnel DaemonSet (L4 — one per node)

```bash
oc --context east get ds -n ztunnel
oc --context west get ds -n ztunnel
```

Expected: `DESIRED = READY` (one ztunnel pod per node).

```bash
oc --context east get pods -n ztunnel -o wide
oc --context west get pods -n ztunnel -o wide
```

Each ztunnel pod should be Running on its respective node.

### 4. Verify istiod (Control Plane)

```bash
oc --context east get pods -n istio-system -l app=istiod
oc --context west get pods -n istio-system -l app=istiod
```

Expected: `1/1 Running` in each cluster.

### 5. Verify namespace enrolled in ambient mesh

```bash
oc --context east get ns bookinfo --show-labels | grep "istio.io/dataplane-mode"
oc --context west get ns bookinfo --show-labels | grep "istio.io/dataplane-mode"
```

Expected: label `istio.io/dataplane-mode=ambient` present.

### 6. Verify NO sidecar in application pods

```bash
oc --context east get pod -n bookinfo -l app=productpage -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
oc --context west get pod -n bookinfo -l app=productpage -o jsonpath='{range .items[0].spec.containers[*]}{.name}{"\n"}{end}'
```

Expected: **only `productpage`** — no `istio-proxy` container. This proves the sidecarless ambient architecture.

For a broader check across all bookinfo pods:

```bash
oc --context east get pods -n bookinfo -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'
```

Every pod should show only its application container (e.g., `productpage`, `details`, `reviews`, `ratings`) with no `istio-proxy`.

## Expected Results

| Component | EAST | WEST |
|-----------|------|------|
| Istio profile | `ambient` | `ambient` |
| IstioCNI | Healthy (v1.27.x) | Healthy (v1.27.x) |
| ztunnel DaemonSet | 1/1 Running per node | 1/1 Running per node |
| istiod | 1/1 Running | 1/1 Running |
| Namespace label | `dataplane-mode=ambient` | `dataplane-mode=ambient` |
| Sidecar (istio-proxy) | **None** | **None** |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| Istio ambient profile | Deploys mesh without sidecars | Yes — mesh architecture |
| IstioCNI | Configures network redirection for ambient | Yes — mesh CNI plugin |
| ztunnel DaemonSet | L4 mTLS, per node, transparent to pods | Yes — L4 data plane |
| istiod | Control plane, pushes config to ztunnel | Yes — control plane |
| `dataplane-mode=ambient` label | Enrolls namespace in the mesh | Yes — mesh enrollment |
| No `istio-proxy` in pods | Proves sidecarless architecture | Yes — ambient mode proof |

## Key Takeaway

In ambient mode, the mesh is provided transparently at the infrastructure level via ztunnel (L4) and optional waypoint proxies (L7). Application pods are never modified — no sidecar injection, no restarts required to join the mesh.
