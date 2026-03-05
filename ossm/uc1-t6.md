# UC1-T6: Infrastructure Segregation (L4 vs Policy)

## Objective

Demonstrate that ztunnel observability (L4) and security policies (AuthorizationPolicy) are independent layers. Two teams can make changes simultaneously without coordination or application pod restarts.

## Quick Run

```bash
./ossm/uc1-t6-verify.sh
```

## Prerequisites

- Both clusters running with bookinfo deployed
- `generate-traffic.sh` running for Kiali visualization
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Test

### 1. Verify baseline

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Confirm HTTP 200 and normal latency. Open bookinfo in browser — reviews section shows normally (with or without stars).

### 2. L4 change (Infra/DevOps team) — Enable ztunnel access logging

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

### 3. Policy change (Security/Dev team) — Deny reviews access from productpage

Apply simultaneously with Step 2:

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

**L4 — ztunnel access logs now visible:**

```bash
oc --context east logs -n ztunnel ds/ztunnel --tail=20 | grep reviews
```

Expected: logs showing connections to reviews with SPIFFE identities, bytes, duration, and DENY errors:

```
error  access  connection complete  src.workload="productpage-v1-..." src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage" dst.service="reviews.bookinfo.svc.cluster.local" ... error="connection closed due to policy rejection: explicitly denied by: bookinfo/deny-reviews-from-productpage"
```

**Policy — reviews blocked in the UI:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Expected: HTTP 200, but open bookinfo in browser — the reviews section shows **"Error fetching product reviews!"** while details and ratings continue working.

### 5. Check Kiali

- **Kiali graph**: traffic edge from productpage to reviews marked in **red** (errors). Rest of the graph stays green.
- **Kiali service detail**: Select `reviews` service — error rate increases to 100%.

### 6. Cleanup

```bash
oc --context east delete authorizationpolicy deny-reviews-from-productpage -n bookinfo
oc --context east delete telemetry ztunnel-logging -n istio-system
```

Reviews section recovers immediately in the browser. No pod restarts needed.

## Expected Results

| Action | Pods restarted | Impact |
|--------|---------------|--------|
| ztunnel Telemetry (L4) | None | Access logs enabled — full connection visibility with SPIFFE identities |
| AuthorizationPolicy DENY (Policy) | None | Reviews blocked instantly — "Error fetching product reviews!" in UI, red edge in Kiali |
| Cleanup | None | Instant recovery, no restarts |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| Telemetry (ztunnel access logging) | L4 observability — connection logs with SPIFFE identities | Yes — mesh telemetry |
| AuthorizationPolicy (DENY) | L7 security — blocks traffic by identity | Yes — mesh security |
| ztunnel | Enforces both changes independently, no restarts | Yes — L4 data plane |
| istiod | Pushes Telemetry and policy config to ztunnel | Yes — control plane |
| Kiali | Shows red edge for denied traffic | Yes — mesh observability |

## Key Takeaway

Infrastructure observability (L4 Telemetry) and security policies (AuthorizationPolicy) are fully decoupled. Different teams operate at different layers without coordination or pod restarts. Changes take effect immediately and are reversible in seconds.
