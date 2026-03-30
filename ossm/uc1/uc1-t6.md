# UC1-T6: Infrastructure Segregation (L4 vs L7)

## Objective

Demonstrate that L4 infrastructure (ztunnel observability) and L7 policies (AuthorizationPolicy via waypoint) are independent layers. Two teams can make changes simultaneously without coordination or application pod restarts.

## Quick Run

```bash
./ossm/uc1-t6-verify.sh
```

## Prerequisites

- Both clusters running with bookinfo deployed
- `generate-traffic.sh` running (for log data)

## Test

### 1. Verify baseline

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Confirm HTTP 200 and normal latency. Open bookinfo in browser — reviews section shows normally (with or without stars).

### 2. Deploy reviews-waypoint (L7 proxy)

The AuthorizationPolicy with `targetRefs` requires a waypoint proxy to enforce L7 policies. Deploy it on demand:

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

### 3. Apply L4 change (ztunnel) + L7 change (waypoint)

Both changes are applied simultaneously — different teams, different layers, no coordination needed.

**L4 (Infra/DevOps team) — Enable ztunnel access logging (no waypoint needed):**

```bash
oc --context east apply -f - <<EOF
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: ztunnel-logging
  namespace: istio-system
spec:
  selector:
    matchLabels:
      app: ztunnel
  accessLogging:
    - providers:
        - name: envoy
      filter:
        expression: "true"
EOF
```

**L7 (Security/Dev team) — Deny reviews from productpage (via waypoint):**

```bash
oc --context east apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-reviews-from-productpage
  namespace: bookinfo
spec:
  targetRefs:
    - kind: Service
      group: ""
      name: reviews
  action: DENY
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/bookinfo/sa/bookinfo-productpage"
EOF
```

> **Note:** In ambient mode, `targetRefs` (pointing to a Service) must be used instead of `selector.matchLabels`. The waypoint proxy enforces the policy on behalf of the target service.

### 4. Verify both changes

**No pod restarts:**

```bash
oc --context east get pods -n bookinfo -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'
```

All pods must show 0 restarts.

**L4 — ztunnel connection logs:**

```bash
oc --context east logs -n ztunnel ds/ztunnel --tail=50 | grep reviews
```

Expected: L4 connection entries showing traffic to reviews with SPIFFE identities, bytes, and duration. Note: ztunnel operates at L4 and sees connections, not HTTP-level denials.

```
info  access  connection complete  src.workload="productpage-v1-..." src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage" dst.service="reviews.bookinfo.svc.cluster.local" ...
```

**L7 — waypoint RBAC stats:**

```bash
WP_POD=$(oc --context east get pods -n bookinfo -l gateway.networking.k8s.io/gateway-name=reviews-waypoint --no-headers | awk '{print $1}' | head -1)
oc --context east exec "$WP_POD" -n bookinfo -- pilot-agent request GET /stats | grep rbac
```

Expected: RBAC denied count greater than 0, confirming the waypoint is enforcing the AuthorizationPolicy at L7:

```
http.inbound_0.0.0.0_9080;.rbac.allowed: 42
http.inbound_0.0.0.0_9080;.rbac.denied: 18
```

> **Note:** RBAC enforcement stats are available directly from the waypoint's Envoy engine via `pilot-agent request GET /stats | grep rbac`. This is the most reliable way to verify denials.

**Policy — reviews blocked in the UI:**

Open bookinfo in browser — the reviews section shows **"Error fetching product reviews!"** while details and ratings continue working. But at the same time `reviews` is still working

```bash
curl -s http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage | grep -o "Error fetching product reviews"

curl http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/reviews/0

```

### 5. Cleanup

```bash
oc --context east delete authorizationpolicy deny-reviews-from-productpage -n bookinfo
oc --context east delete telemetry ztunnel-logging -n istio-system
oc --context east label svc reviews -n bookinfo istio.io/use-waypoint-
oc --context east delete gateway reviews-waypoint -n bookinfo
```

Reviews section recovers immediately in the browser. No pod restarts needed. The waypoint proxy (L7) is removed, returning to the L4-only ztunnel baseline.

## Expected Results

| Action | Pods restarted | Impact |
|--------|---------------|--------|
| L4: ztunnel Telemetry | None | Access logs enabled — full connection visibility with SPIFFE identities |
| L7: AuthorizationPolicy DENY (waypoint) | None | Reviews blocked instantly — "Error fetching product reviews!" in UI, `rbac.denied` count in waypoint stats |
| Cleanup | None | Instant recovery, no restarts |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| Telemetry (ztunnel access logging) | L4 observability — connection logs with SPIFFE identities | Yes — mesh telemetry |
| AuthorizationPolicy (DENY) | L7 security — blocks traffic by identity via waypoint | Yes — mesh security |
| ztunnel | L4 data plane — mTLS, telemetry, connection-level enforcement | Yes — L4 data plane |
| Waypoint proxy | L7 data plane — HTTP-level policy enforcement (AuthorizationPolicy) | Yes — L7 data plane |
| istiod | Pushes Telemetry and policy config to ztunnel and waypoint | Yes — control plane |

## Key Takeaway

L4 infrastructure (ztunnel Telemetry) and L7 policies (AuthorizationPolicy via waypoint) are fully decoupled. Different teams operate at different layers — L4 changes go through ztunnel, L7 changes go through the waypoint proxy — without coordination or pod restarts. Changes take effect immediately and are reversible in seconds.
