# UC1-T1: Baseline OpenShift Environments

## Objective

Show two OCP 4.20 clusters (EAST and WEST) with Red Hat OpenShift Service Mesh 3 operator installed, plus a third cluster (ACM) acting as the management hub. Establish the baseline for the environment.

## Prerequisites

- `oc` CLI installed
- Contexts configured: `acm`, `east`, `west`
- Logged in to all three clusters

## Quick Run

Run the verification script:

```bash
./ossm/uc1-t1-verify.sh
```

## Manual Steps

### 1. Verify cluster access and OCP version

```bash
oc --context east version
oc --context west version
oc --context acm version
```

Expected: Server Version `4.20.x` on all three clusters.

### 2. Verify nodes are Ready

```bash
oc --context east get nodes
oc --context west get nodes
oc --context acm get nodes
```

All nodes should show `STATUS: Ready`.

### 3. Verify Service Mesh operator on EAST and WEST

```bash
oc --context east get csv -n openshift-operators | grep servicemesh
oc --context west get csv -n openshift-operators | grep servicemesh
```

Expected: `Red Hat OpenShift Service Mesh 3` with status `Succeeded`.

### 4. Verify Istio control plane

```bash
oc --context east get istio -n istio-system
oc --context west get istio -n istio-system
```

Expected: `STATUS: Healthy`, `VERSION: v1.27.x`.

### 5. Verify ACM managed clusters

```bash
oc --context acm get managedclusters
```

Expected: EAST and WEST clusters listed and available.

### 6. Verify mesh components running

```bash
oc --context east get pods -n istio-system
oc --context west get pods -n istio-system
oc --context east get pods -n ztunnel
oc --context west get pods -n ztunnel
```

Expected: `istiod` running in both clusters, `ztunnel` DaemonSet running on each node.

## Expected Results

| Component | EAST | WEST | ACM |
|-----------|------|------|-----|
| OCP Version | 4.20.x | 4.20.x | 4.20.x |
| Nodes Ready | Yes | Yes | Yes |
| OSSM 3 Operator | Succeeded (v3.2.x) | Succeeded (v3.2.x) | N/A |
| Istio CR | Healthy (v1.27.x) | Healthy (v1.27.x) | N/A |
| istiod | Running | Running | N/A |
| ztunnel | Running | Running | N/A |
| Managed Clusters | — | — | EAST + WEST available |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| OSSM 3 Operator | Installs and manages Istio lifecycle | Yes — mesh operator |
| Istio CR (Healthy) | Declares the mesh control plane | Yes — control plane config |
| istiod | Control plane, manages mesh config and certs | Yes — control plane |
| ztunnel DaemonSet | L4 data plane, mTLS, per node | Yes — L4 data plane |
| ACM | Centralized multi-cluster management | Kubernetes (support) |

## Key Takeaway

The baseline environment provides two independent OCP 4.20 clusters with OSSM 3.2 operator installed and a healthy Istio control plane. ACM acts as the centralized management hub. This is the foundation for all subsequent use cases.
