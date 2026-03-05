# UC3-T2: Adding Intelligence — Canary Deployment (East-West via Waypoint)

> **Alcance**: El caso de uso original plantea contexto multi-cluster (EAST→WEST). En OSSM 3.2 (Istio 1.27) ambient mode, el data plane cross-cluster no soporta waypoints, por lo que aquí se demuestra la misma funcionalidad single-cluster. La mecánica es idéntica y se extenderá a multi-cluster con Istio 1.29+.

## Objective

Demonstrate that the **waypoint proxy** can perform weighted traffic routing between service versions via `HTTPRoute` (Gateway API), enabling canary deployments for **all mesh-internal (east-west) traffic** — not just traffic entering through the ingress gateway.

This is fundamentally different from UC12 (HTTPRoute at the ingress gateway): here the routing applies to **every call to `reviews`** regardless of origin (productpage, other services, or any mesh client), because it is enforced by the **reviews-waypoint** at the destination.

## Prerequisites

- Both clusters running with bookinfo deployed and accessible
- `generate-traffic.sh` running for Kiali visualization (recommended — shows traffic split in real-time)
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Quick Run

```bash
./ossm/uc3-t2-verify.sh
```

## Architecture

### UC12 vs UC3-T2 — same API, different enforcement point

```
UC12: HTTPRoute at ingress gateway (north-south only)
┌─────────────────────────────────────────────────────────┐
│ external user → OpenShift Route → ingress gateway       │
│                                   (HTTPRoute weights)   │
│                                    ├──→ reviews-v1 90%  │
│                                    └──→ reviews-v3 10%  │
│                                                         │
│ productpage → reviews   (NOT affected by HTTPRoute)     │
└─────────────────────────────────────────────────────────┘

UC3-T2: HTTPRoute at waypoint (east-west — all traffic)
┌─────────────────────────────────────────────────────────┐
│ external user → ingress → productpage → reviews-waypoint│
│                                    (HTTPRoute weights)  │
│                                     ├──→ v1 90%         │
│                                     └──→ v3 10%         │
│                                                         │
│ any-service → reviews-waypoint  (ALSO affected)         │
│               (HTTPRoute weights)                       │
│                ├──→ v1 90%                              │
│                └──→ v3 10%                              │
└─────────────────────────────────────────────────────────┘
```

The key difference is `parentRefs`: UC12 targets a `Gateway` (ingress), UC3-T2 targets a `Service` (mesh-internal via waypoint).

This is what **only a service mesh can do**: control traffic routing between services at L7, transparently, without application changes.

### HTTPRoute parentRefs comparison

```yaml
# UC12 — ingress gateway (north-south)
parentRefs:
- kind: Gateway
  name: bookinfo-gateway

# UC3-T2 — waypoint proxy (east-west)
parentRefs:
- kind: Service
  group: ""
  name: reviews
  port: 9080
```

## Manual Steps

### 1. Create version-specific services (routing targets)

HTTPRoute uses `backendRefs` to route to Kubernetes Services. We create version-specific services to split traffic:

```bash
oc --context east apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: reviews-v1-only
  namespace: bookinfo
spec:
  ports:
  - port: 9080
    name: http
  selector:
    app: reviews
    version: v1
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v3-only
  namespace: bookinfo
spec:
  ports:
  - port: 9080
    name: http
  selector:
    app: reviews
    version: v3
EOF
```

### 2. Verify baseline — traffic goes to all versions

```bash
PRODUCTPAGE_POD=$(oc --context east get pods -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
oc --context east exec -n bookinfo "$PRODUCTPAGE_POD" -- python3 -c "
import urllib.request, json, time
for i in range(6):
    time.sleep(1)
    try:
        req = urllib.request.Request('http://reviews:9080/reviews/0')
        with urllib.request.urlopen(req, timeout=10) as resp:
            pod = json.loads(resp.read().decode()).get('podname', '?')
            print(f'  [{i+1}] {pod}')
    except Exception as e:
        print(f'  [{i+1}] error: {type(e).__name__}')
"
```

Expected: responses from v1, v2, and v3 (round-robin).

### 3. Deploy reviews-waypoint (L7 proxy)

The HTTPRoute with `parentRefs` targeting a Service requires a waypoint proxy. Deploy it on demand:

```bash
oc --context east apply -f - <<EOF
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

oc --context east label svc reviews -n bookinfo istio.io/use-waypoint=reviews-waypoint --overwrite
oc --context east wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=reviews-waypoint -n bookinfo --timeout=60s
```

### 4. Phase A: Apply HTTPRoute — 100% v1

```bash
oc --context east apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1-only
      port: 9080
      weight: 100
    - name: reviews-v3-only
      port: 9080
      weight: 0
EOF
```

Expected: **only reviews-v1** pods in the responses.

### 5. Phase B: Canary 50/50 — split traffic

```bash
oc --context east apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1-only
      port: 9080
      weight: 50
    - name: reviews-v3-only
      port: 9080
      weight: 50
EOF
```

Expected: ~50% reviews-v1, ~50% reviews-v3.

### 6. Phase C: Promotion — 100% v3

```bash
oc --context east apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews-canary
  namespace: bookinfo
spec:
  parentRefs:
  - kind: Service
    group: ""
    name: reviews
    port: 9080
  rules:
  - backendRefs:
    - name: reviews-v1-only
      port: 9080
      weight: 0
    - name: reviews-v3-only
      port: 9080
      weight: 100
EOF
```

Expected: **only reviews-v3** pods in the responses.

### 7. Cleanup

```bash
oc --context east delete httproute reviews-canary -n bookinfo
oc --context east delete svc reviews-v1-only reviews-v3-only -n bookinfo
oc --context east label svc reviews -n bookinfo istio.io/use-waypoint-
oc --context east delete gateway reviews-waypoint -n bookinfo
```

### 8. Verify recovery

```bash
curl -s -o /dev/null -w "EAST: HTTP %{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Expected: HTTP 200, normal round-robin to all versions restored.

## Expected Results

| Phase | v1 traffic | v3 traffic | v2 traffic |
|-------|-----------|-----------|-----------|
| Baseline (no HTTPRoute) | ~33% | ~33% | ~33% |
| 100% v1 | **100%** | 0% | 0% |
| 50/50 canary | ~50% | ~50% | 0% |
| 100% v3 (promoted) | 0% | **100%** | 0% |
| After cleanup | ~33% | ~33% | ~33% |

## UC12 vs UC3-T2 Comparison

| Aspect | UC12 (ingress) | UC3-T2 (waypoint) |
|--------|----------------|---------------------|
| API | HTTPRoute (Gateway API, GA) | HTTPRoute (Gateway API, GA) |
| parentRefs target | `Gateway` (ingress) | `Service` (mesh-internal) |
| Enforced at | Ingress gateway (north-south) | Waypoint proxy (east-west) |
| Scope | Only external traffic via Route | **All** traffic to the service |
| Mesh feature? | Could be done with any ingress controller | **Only possible with a service mesh** |

> **Alternativa VirtualService**: La misma funcionalidad puede lograrse con `VirtualService` + `DestinationRule` (subsets). VirtualService usa subsets con labels en lugar de Services separados. Esta alternativa está documentada como referencia en [UC20-T7](./uc20-t7-canary-vs.md) (Technology Preview en OSSM 3.2).

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| HTTPRoute (weights) | Configures canary traffic split between versions | Yes — traffic management (GA) |
| reviews-v1-only / v3-only (Services) | Version-specific routing targets for HTTPRoute | No — standard K8s |
| reviews-waypoint | Enforces weighted routing for all inbound traffic | Yes — L7 data plane |
| ztunnel | Routes traffic through waypoints (HBONE) | Yes — L4 data plane |
| istiod | Pushes HTTPRoute config to waypoints | Yes — control plane |

## Key Takeaway

Canary deployments at the **waypoint level** apply to all east-west traffic reaching a service — not just external traffic at the ingress. Using `HTTPRoute` with `parentRefs` targeting a `Service` (instead of a `Gateway`), the same standard Kubernetes API controls traffic at both the edge and inside the mesh. This is what **only a service mesh can do**: split traffic between services inside the cluster, transparently, without application changes. The waypoint proxy enforces the weighted routing for every caller in the mesh, making canary deployments a true infrastructure concern — invisible to applications.
