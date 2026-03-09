# UC3-T3: The "Follow-the-Service" Migration

## Objective

Demonstrate that the mesh's internal control plane handles service resolution transparently when a service **migrates** from one cluster to another. The calling service (`productpage`) continues using the same internal hostname `reviews.bookinfo.svc.cluster.local` — no external DNS reconfiguration, no F5 health checks, no application changes. The mesh's global endpoint registry (istiod + remote secrets) resolves the service wherever it lives.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`
- Istio 1.29 Multi-Primary federation active (remote secrets configured)
- bookinfo application deployed in namespace `bookinfo` on both clusters
- Ambient mode enabled on `bookinfo` namespace
- `generate-traffic.sh` running (recommended — shows live migration in Kiali)

## Quick Run

```bash
./istio/uc3-t3-verify.sh
```

## Architecture

### Traditional migration vs Mesh migration

```
Traditional migration (requires external coordination):
┌──────────────────────────────────────────────────────────────┐
│ 1. Deploy service-B in EAST                                  │
│ 2. Update F5/external LB health checks                       │
│ 3. Update corporate DNS to point to EAST                     │
│ 4. Wait for DNS TTL propagation (minutes to hours)           │
│ 5. Verify traffic flows to EAST                              │
│ 6. Decommission service-B in WEST                            │
│ 7. Remove old DNS/F5 entries                                 │
└──────────────────────────────────────────────────────────────┘

Mesh migration (zero external coordination):
┌──────────────────────────────────────────────────────────────┐
│ 1. Scale service-B to 0 in WEST                              │
│ 2. Done. istiod updates global endpoints automatically.      │
│    Traffic resolves to EAST via reviews.bookinfo.svc...      │
│    No DNS change. No LB change. No application change.       │
└──────────────────────────────────────────────────────────────┘
```

### Internal resolution flow

```
Before migration (WEST active):
  productpage → reviews.bookinfo.svc.cluster.local
                  ├──→ reviews-v1 (EAST2)
                  ├──→ reviews-v2 (EAST2)  
                  ├──→ reviews-v3 (EAST2)
                  ├──→ reviews-v1 (WEST2)  ←── via East-West GW
                  ├──→ reviews-v2 (WEST2)  ←── via East-West GW
                  └──→ reviews-v3 (WEST2)  ←── via East-West GW

After migration (WEST scaled to 0):
  productpage → reviews.bookinfo.svc.cluster.local   ← SAME hostname
                  ├──→ reviews-v1 (EAST2)  ←── all local now
                  ├──→ reviews-v2 (EAST2)
                  └──→ reviews-v3 (EAST2)
```

The hostname `reviews.bookinfo.svc.cluster.local` never changes. istiod removes WEST2 endpoints from the global registry and traffic resolves to EAST2 automatically.

## Manual Steps

### 1. Verify baseline — reviews running in both clusters

```bash
oc --context east2 get pods -n bookinfo -l app=reviews
oc --context west2 get pods -n bookinfo -l app=reviews
```

Send traffic from productpage to reviews (internal call) and note the pod names — responses should come from both EAST2 and WEST2 pods.

### 2. Simulate migration — scale reviews to 0 in WEST2

```bash
oc --context west2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=0
```

### 3. Verify internal resolution

From inside the productpage pod, call `reviews.bookinfo.svc.cluster.local` — the same hostname, no changes:

```bash
PP_POD=$(oc --context east2 get pods -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
oc --context east2 exec -n bookinfo "$PP_POD" -- \
  python3 -c "import urllib.request; print(urllib.request.urlopen('http://reviews:9080/reviews/0', timeout=10).read().decode()[:100])"
```

Expected: a valid JSON response with a `podname` from EAST2. The hostname `reviews:9080` resolved without any DNS or LB changes.

### 4. Restore — scale reviews back in WEST2

```bash
oc --context west2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=1
```

## Expected Results

| Phase | reviews in EAST2 | reviews in WEST2 | Internal hostname | Traffic |
|---|---|---|---|---|
| Baseline | 3 pods Running | 3 pods Running | `reviews.bookinfo.svc...` | Distributed (both clusters) |
| Migration | 3 pods Running | **0 pods** | `reviews.bookinfo.svc...` (same) | **100% EAST2** |
| Restore | 3 pods Running | 3 pods Running | `reviews.bookinfo.svc...` (same) | Distributed (both clusters) |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| istiod (per cluster) | Maintains global endpoint registry via remote secrets | Yes — control plane federation |
| Remote secrets | Allow each istiod to discover services across clusters | Yes — multi-cluster discovery |
| ztunnel | Resolves `svc.cluster.local` to available endpoints (local or remote) | Yes — L4 data plane |
| East-West Gateway | Bridges HBONE traffic between clusters transparently | Yes — multi-cluster data plane |
| Global endpoint registry | istiod merges local + remote endpoints; removes unavailable ones automatically | Yes — service discovery |

## Key Takeaway

Service migration between clusters requires **zero external coordination** when a service mesh is in place. The internal hostname `reviews.bookinfo.svc.cluster.local` resolves to available endpoints regardless of which cluster hosts them. There is no DNS TTL to wait for, no F5 health check to reconfigure, no corporate LB rule to update. The mesh's control plane handles the global endpoint registry — making service location an infrastructure concern invisible to applications.
