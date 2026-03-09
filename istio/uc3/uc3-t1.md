# UC3-T1: One Mesh Multi-Cluster Connectivity (The L4 Foundation)

## Objective

Demonstrate that the Istio ambient mesh provides **transparent L4 cross-cluster connectivity** between services. Traffic from a client in Cluster EAST is encapsulated in **HBONE (mTLS over port 15008)** by ztunnel and routed through the East-West Gateway to a service in Cluster WEST — bypassing all external corporate load balancers at the application layer.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`
- Istio 1.29 Multi-Primary federation active (remote secrets configured)
- bookinfo application deployed in namespace `bookinfo` on both clusters
- East-West Gateways running in `istio-system` on both clusters
- `generate-traffic.sh` running (optional, for Kiali visualization)

## Quick Run

```bash
./istio/uc3-t1-verify.sh
```

## Manual Steps

### 1. Verify multi-cluster infrastructure

Confirm that each cluster has the L4 foundation: ztunnel, east-west gateway, and remote secrets.

```bash
# ztunnel (L4 data plane, one per node)
oc --context east2 get pods -n istio-system -l app=ztunnel
oc --context west2 get pods -n istio-system -l app=ztunnel

# East-West Gateway (bridges HBONE traffic between clusters)
oc --context east2 get pods -n istio-system -l app=istio-eastwestgateway
oc --context west2 get pods -n istio-system -l app=istio-eastwestgateway

# Remote secrets (allow istiod to discover the other cluster's endpoints)
oc --context east2 get secrets -n istio-system -l istio/multiCluster=true
oc --context west2 get secrets -n istio-system -l istio/multiCluster=true
```

Expected: ztunnel Running, east-west gateway Running with LoadBalancer external IP, remote secrets present on both clusters.

### 2. Force cross-cluster traffic and verify L4 path

Scale reviews to 0 in EAST2 to force productpage to reach reviews in WEST2:

```bash
oc --context east2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=0
```

Generate traffic and verify connectivity:

```bash
curl -s -m 15 \
  "http://$(oc --context east2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage" \
  | grep -c "Book Reviews"
# Expected: 1 (reviews served from WEST2 via L4 HBONE path)
```

### 3. Inspect ztunnel logs — HBONE evidence

The ztunnel access logs on WEST2 show the L4 path with SPIFFE identities and HBONE port 15008:

```bash
oc --context west2 logs -n istio-system -l app=ztunnel --tail=100 \
  | grep "access" | grep "reviews" | tail -3
```

Key fields to observe in the logs:
- `src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"` — caller's cryptographic identity
- `dst.hbone_addr=...:9080` — HBONE tunnel destination
- `dst.addr=...:15008` — HBONE port
- `direction="outbound"` / `"inbound"` — traffic direction

### 4. Verify East-West Gateway role

The East-West Gateway is the bridge between clusters, exposing port 15008 for HBONE:

```bash
oc --context east2 get svc istio-eastwestgateway -n istio-system
oc --context west2 get svc istio-eastwestgateway -n istio-system
```

Expected: LoadBalancer with external hostname, ports 15021 and 15008.

### 5. Recovery

```bash
oc --context east2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=1
```

## The HBONE Bypass

```
                     Corporate Network Boundary
                     ══════════════════════════
    EAST2                                              WEST2
    ─────                                              ─────
    productpage                                        reviews
        │                                                 ▲
        ▼                                                 │
    ztunnel ──HBONE/mTLS──> East-West GW ════> East-West GW ──> ztunnel
              (port 15008)    (AWS ELB)          (AWS ELB)       (port 15008)

    ✓ Traffic is mTLS-encrypted end-to-end (SPIFFE certificates)
    ✓ HBONE encapsulation (HTTP/2 CONNECT over mTLS)
    ✓ Corporate LBs see only opaque encrypted traffic on port 15008
    ✓ No application-layer inspection possible by intermediate infrastructure
```

## Expected Results

| Component | EAST2 | WEST2 |
|---|---|---|
| ztunnel | Running (1 per node) | Running (1 per node) |
| East-West Gateway | Running, LoadBalancer with ELB | Running, LoadBalancer with ELB |
| Remote secrets | `istio-remote-secret-west2` present | `istio-remote-secret-east2` present |
| Cross-cluster HTTP | HTTP 200 (reviews from WEST2) | Serving reviews traffic |
| ztunnel logs | HBONE on port 15008, SPIFFE identities | Inbound connections with SPIFFE IDs |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| ztunnel | Intercepts traffic, establishes HBONE mTLS tunnels | Yes — L4 data plane |
| HBONE (port 15008) | HTTP/2 CONNECT over mTLS — the ambient transport protocol | Yes — mesh transport |
| East-West Gateway | Bridges HBONE tunnels between clusters through AWS ELBs | Yes — multi-cluster data plane |
| SPIFFE certificates | Cryptographic workload identity for mTLS authentication | Yes — mesh identity |
| Remote secrets | Allow istiod to discover services across clusters | Yes — multi-cluster control plane |
| istiod | Merges local + remote endpoints for routing decisions | Yes — service discovery |

## Key Takeaway

The ambient mesh establishes a secure L4 foundation where all inter-service traffic is automatically encrypted with mTLS via HBONE tunnels. The East-West Gateway bridges these tunnels across cluster boundaries, meaning that corporate load balancers and intermediate infrastructure only see opaque encrypted traffic on port 15008 — they cannot inspect or interfere with application-layer data. This provides true end-to-end encryption with zero application changes.
