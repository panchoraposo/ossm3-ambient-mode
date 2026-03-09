# UC1-T4: Resilience & Failover (Cross-Cluster)

## Objective

Demonstrate that the Istio ambient mesh provides **automatic cross-cluster failover** when all replicas of a service are unavailable in the local cluster. Traffic is transparently rerouted through the East-West Gateway to healthy replicas in the remote cluster — with no application changes and no manual intervention.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`
- Istio 1.29 Multi-Primary federation active (remote secrets configured)
- bookinfo application deployed in namespace `bookinfo` on both clusters
- Ambient mode enabled (`istio.io/dataplane-mode: ambient` on `bookinfo` namespace)
- `generate-traffic.sh` running (optional, for Kiali visualization)

## Quick Run

```bash
./istio/uc1-t4-verify.sh
```

## Manual Steps

### 1. Verify baseline — reviews running in both clusters

```bash
oc --context east2 get pods -n bookinfo -l app=reviews
oc --context west2 get pods -n bookinfo -l app=reviews
```

Expected: `reviews-v1`, `reviews-v2`, `reviews-v3` all `1/1 Running` in both clusters.

```bash
oc --context east2 get endpoints reviews -n bookinfo
```

Expected: three endpoint IPs listed.

Baseline request to EAST2:

```bash
curl -s -o /dev/null -w "%{http_code}" -m 15 \
  "http://$(oc --context east2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"
```

Expected: `200`.

### 2. Failover — scale reviews to zero in EAST2 and verify

Scale down all reviews replicas:

```bash
oc --context east2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=0
```

Verify no local endpoints remain:

```bash
oc --context east2 get endpoints reviews -n bookinfo
```

Expected: `ENDPOINTS = <none>`.

Now send requests to productpage in EAST2. Despite having no local reviews pods, the mesh routes traffic to WEST2 transparently:

```bash
curl -s -m 15 \
  "http://$(oc --context east2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage" \
  | grep -c "Book Reviews"
```

Expected: `1` — the Book Reviews section is present with star ratings, proving that productpage reached reviews in WEST2 via the East-West Gateway.

The traffic flow during failover:

```
productpage (EAST2) → ztunnel → East-West GW ══HBONE/15443══> WEST2 → reviews ✓
```

Verify visually in the browser using the EAST2 bookinfo URL — the page should display the Book Reviews section normally despite having no local reviews replicas.

### 3. Recovery — restore reviews in EAST2

```bash
oc --context east2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=1
```

Verify pods are back and endpoints are populated:

```bash
oc --context east2 get pods -n bookinfo -l app=reviews
oc --context east2 get endpoints reviews -n bookinfo
```

Expected: three pods `1/1 Running`, endpoints restored, HTTP 200 on productpage.

## Expected Results

| Step | EAST2 | WEST2 |
|---|---|---|
| Baseline | reviews Running (3 pods), HTTP 200 | reviews Running (3 pods) |
| Scale to 0 | reviews pods = 0, endpoints = `<none>` | reviews Running (3 pods) |
| Failover | HTTP 200, Book Reviews present (served from WEST2) | Serving cross-cluster traffic |
| Response time | 0.4–0.7s per request (includes cross-cluster latency) | — |
| Recovery | reviews Running (3 pods), endpoints restored, HTTP 200 | reviews Running (3 pods) |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| istiod (per cluster) | Discovers remote endpoints via remote secrets | Yes — control plane federation |
| Remote secrets | Allow each istiod to see the other cluster's services | Yes — multi-cluster discovery |
| ztunnel | Intercepts traffic and routes to East-West GW when local endpoints are absent | Yes — L4 data plane |
| East-West Gateway | Bridges HBONE traffic between clusters on port 15443 | Yes — multi-cluster data plane |
| Endpoint discovery | istiod merges local + remote endpoints for load balancing decisions | Yes — service discovery |
| Automatic failover | No configuration needed — the mesh detects absent endpoints and reroutes | Yes — built-in resilience |

## Key Takeaway

The ambient mesh provides automatic cross-cluster failover without any application changes or explicit resilience configuration. When local endpoints disappear, istiod's federated service discovery detects healthy replicas in the remote cluster and ztunnel reroutes traffic through the East-West Gateway — achieving sub-second failover transparent to both the application and the end user.
