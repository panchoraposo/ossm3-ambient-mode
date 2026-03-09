# UC4-T1: Cross-Cluster Traffic Generation (Observability Foundation)

## Objective

Establish **active cross-cluster communication** between federated clusters and verify that the mesh **populates telemetry automatically**. Traffic flows through the East-West Gateways using the **shared trust domain** (`cluster.local`), and every request is visible in Kiali's real-time graph — with no application instrumentation or telemetry configuration required.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`, `acm2`
- Istio 1.29 Multi-Primary federation active (remote secrets configured)
- bookinfo application deployed in namespace `bookinfo` on both clusters
- Ambient mode enabled on `bookinfo` namespace
- Kiali accessible on `acm2` (centralized observability hub)

## Quick Run

```bash
./istio/uc4-t1-verify.sh
```

## Architecture

### Cross-cluster traffic flow with telemetry

```
                        Shared Trust Domain: cluster.local
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                  │
  │  EAST2                          WEST2                            │
  │  ─────                          ─────                            │
  │  productpage ──→ ztunnel       ztunnel ──→ reviews               │
  │       │              │              ▲           │                 │
  │       │              ▼              │           ▼                 │
  │       │         EW-Gateway ═══> EW-Gateway    ratings            │
  │       │         (HBONE/15008)                                    │
  │       ▼                                                          │
  │   reviews (local)                                                │
  │   ratings (local)                                                │
  │   details (local)                                                │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                     ┌────────────────┐
                     │  ACM2 (Hub)    │
                     │  ─────────     │
                     │  Kiali         │   ← real-time cross-cluster
                     │  Prometheus    │      service graph
                     │  (promxy)      │
                     └────────────────┘
```

### What telemetry gets populated

| Metric / Signal | Source | Content |
|---|---|---|
| Request count, latency, error rate | ztunnel (L4) | TCP bytes, connections, durations |
| Service-to-service edges | istiod endpoint merging | Cross-cluster topology graph |
| SPIFFE identity | mTLS certificates | `spiffe://cluster.local/ns/bookinfo/sa/...` |
| Cluster origin | pod metadata | `clustername` field in responses |

## Manual Steps

### 1. Verify both clusters serve bookinfo

```bash
# EAST2
curl -s -o /dev/null -w "%{http_code}" -m 15 \
  "http://$(oc --context east2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"

# WEST2
curl -s -o /dev/null -w "%{http_code}" -m 15 \
  "http://$(oc --context west2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"
```

Expected: `200` from both.

### 2. Generate sustained cross-cluster traffic

Use the traffic generator to send parallel requests to both entry points:

```bash
./generate-traffic.sh
```

Or generate directly from inside the mesh to force internal cross-cluster calls:

```bash
PP_POD=$(oc --context east2 get pods -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 20); do
  oc --context east2 exec -n bookinfo "$PP_POD" -- \
    python3 -c "import urllib.request; print(urllib.request.urlopen('http://reviews:9080/reviews/0', timeout=10).read().decode()[:80])"
  sleep 0.5
done
```

Traffic distributes across local (EAST2) and remote (WEST2) reviews pods.

### 3. Verify cross-cluster distribution

Check that responses come from **both clusters** by examining the `clustername` and `podname` fields:

```bash
PP_POD=$(oc --context east2 get pods -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 10); do
  oc --context east2 exec -n bookinfo "$PP_POD" -- \
    python3 -c "import urllib.request,json; r=json.loads(urllib.request.urlopen('http://reviews:9080/reviews/0', timeout=10).read()); print(r.get('clustername','?'), r.get('podname','?'))"
  sleep 0.5
done
```

Expected: a mix of `east2` and `west2` cluster names.

### 4. Verify in Kiali

Open the Kiali dashboard on the ACM2 hub and look for:

- Service-to-service edges between `productpage` → `reviews`, `reviews` → `ratings`
- Cross-cluster traffic indicators
- Response time and success rate metrics populated in edge labels

```bash
oc --context acm2 get route kiali -n istio-system -o jsonpath='{.spec.host}'
```

### 5. Verify SPIFFE identities (shared trust domain)

```bash
oc --context west2 logs -n istio-system -l app=ztunnel --tail=50 \
  | grep "access" | grep "reviews" | head -3
```

Look for `src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"` — proving the shared trust domain is active across clusters.

## Expected Results

| Verification | Expected |
|---|---|
| EAST2 productpage | HTTP 200 |
| WEST2 productpage | HTTP 200 |
| Internal cross-cluster calls | Responses from both `east2` and `west2` pods |
| Kiali graph | Service edges populated with traffic metrics |
| SPIFFE identities | `spiffe://cluster.local/ns/bookinfo/sa/...` in ztunnel logs |
| Shared trust domain | Both clusters use `cluster.local` — same root CA |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| ztunnel | Intercepts traffic and generates L4 telemetry (TCP metrics) | Yes — L4 data plane + telemetry |
| HBONE (port 15008) | Encrypted transport between clusters — generates connection metrics | Yes — mesh transport |
| East-West Gateway | Bridges HBONE tunnels — traffic is metered at both ends | Yes — multi-cluster data plane |
| istiod | Merges endpoints from both clusters for load balancing | Yes — service discovery |
| Shared trust domain | `cluster.local` — same root CA allows mTLS without extra config | Yes — mesh identity |
| Kiali (on ACM2) | Aggregates telemetry from both clusters into a unified graph | Yes — centralized observability |
| promxy (on ACM2) | Fans out Prometheus queries to both clusters | Yes — centralized metrics |

## Key Takeaway

The mesh populates cross-cluster telemetry **automatically** — no application instrumentation, no OpenTelemetry SDKs, no sidecar injection annotations. Every request that flows through the ambient data plane (ztunnel) generates metrics that Kiali aggregates into a real-time service graph spanning both clusters. The shared trust domain (`cluster.local`) ensures that SPIFFE identities are consistent across cluster boundaries, making cross-cluster traffic indistinguishable from local traffic in the observability layer.
