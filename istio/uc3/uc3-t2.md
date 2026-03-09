# UC3-T2: Adding Intelligence — Canary Deployment (East-West via Waypoint)

## Objective

Demonstrate that the **waypoint proxy** can perform weighted traffic routing between service versions via `VirtualService` + `DestinationRule` (subsets), enabling canary deployments for **all mesh-internal (east-west) traffic** — not just traffic entering through the ingress gateway.

The routing applies to **every call to `reviews`** regardless of origin, because it is enforced by the **reviews-waypoint** at the destination.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`
- Istio 1.29 Multi-Primary federation active
- bookinfo application deployed in namespace `bookinfo` on both clusters
- No pre-existing waypoints (clean L4 baseline)
- `generate-traffic.sh` running for Kiali visualization (recommended)

## Quick Run

```bash
./istio/uc3-t2-verify.sh
```

## Architecture

### Why VirtualService + DestinationRule (not HTTPRoute backendRefs)

In Istio 1.29 ambient mode, the waypoint proxy creates `inbound-vip` clusters for the parent service that use HBONE transport. When an HTTPRoute routes to a **different** service via `backendRefs`, it creates an `outbound` cluster without HBONE — causing `502 protocol_error`.

VirtualService + DestinationRule uses **subsets** (label-based filters on the same service), which correctly map to the waypoint's internal HBONE clusters:

```
inbound-vip|9080|http/v1|reviews.bookinfo.svc.cluster.local  → internal_upstream (HBONE)
inbound-vip|9080|http/v3|reviews.bookinfo.svc.cluster.local  → internal_upstream (HBONE)
```

### Multi-cluster consideration

In multi-cluster, the east-west gateway is an opaque L4 tunnel (HBONE on port 15008). It does not apply L7 subset filtering. To ensure clean canary routing, the script scales WEST2 reviews replicas to 0 during the canary phases, forcing all traffic to local EAST2 reviews where the waypoint enforces the routing policy.

```
productpage (EAST2) → ztunnel → reviews-waypoint (L7)
                                  ├──→ reviews-v1 (local, EAST2)  weight: X%
                                  └──→ reviews-v3 (local, EAST2)  weight: Y%

WEST2 reviews: scaled to 0 during canary (restored at cleanup)
```

## Manual Steps

### 1. Scale WEST2 reviews to 0

```bash
oc --context west2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=0
```

### 2. Deploy reviews-waypoint

```bash
oc --context east2 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: reviews-waypoint
  namespace: bookinfo
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
EOF

oc --context east2 label svc reviews -n bookinfo istio.io/use-waypoint=reviews-waypoint --overwrite
```

### 3. Apply DestinationRule + VirtualService (100% v1)

```bash
oc --context east2 apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: reviews-versions
  namespace: bookinfo
spec:
  host: reviews.bookinfo.svc.cluster.local
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v3
    labels:
      version: v3
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  hosts:
  - reviews.bookinfo.svc.cluster.local
  http:
  - route:
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v1
      weight: 100
    - destination:
        host: reviews.bookinfo.svc.cluster.local
        subset: v3
      weight: 0
EOF
```

Expected: **only reviews-v1** pods in responses (no stars in the browser).

### 4. Phase B: Canary 50/50

Change weights to 50/50 in the VirtualService.

### 5. Phase C: Promotion — 100% v3

Change weights to 0/100 in the VirtualService.

### 6. Cleanup

```bash
oc --context east2 delete virtualservice reviews-canary -n bookinfo
oc --context east2 delete destinationrule reviews-versions -n bookinfo
oc --context east2 label svc reviews -n bookinfo istio.io/use-waypoint-
oc --context east2 delete gateway reviews-waypoint -n bookinfo
oc --context west2 scale deployment reviews-v1 reviews-v2 reviews-v3 \
  -n bookinfo --replicas=1
```

## Expected Results

| Phase | v1 traffic | v3 traffic | v2 traffic |
|---|---|---|---|
| Baseline (no waypoint) | ~33% | ~33% | ~33% |
| 100% v1 | **100%** | 0% | 0% |
| 50/50 canary | ~50% | ~50% | 0% |
| 100% v3 (promoted) | 0% | **100%** | 0% |
| After cleanup | ~33% | ~33% | ~33% |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| VirtualService (weights) | Configures canary traffic split between subsets | Yes — traffic management |
| DestinationRule (subsets) | Maps version labels to named subsets | Yes — traffic management |
| reviews-waypoint | Enforces weighted routing for all inbound traffic | Yes — L7 data plane |
| ztunnel | Routes traffic through waypoints (HBONE) | Yes — L4 data plane |
| istiod | Pushes VirtualService config to waypoints | Yes — control plane |

## Key Takeaway

Canary deployments at the **waypoint level** apply to all east-west traffic reaching a service — not just external traffic at the ingress. The waypoint proxy enforces weighted routing for every caller, making canary deployments a true infrastructure concern — invisible to applications. In multi-cluster, L7 routing is enforced locally by the waypoint; the east-west gateway operates at L4 (opaque HBONE tunnel), so canary policies must be applied on the cluster where routing decisions are made.
