# UC2-T1: The "Lockdown" (Deny-All Everywhere)

## Objective

Apply a global deny-all AuthorizationPolicy to the root namespace of the mesh (`istio-system`) and verify that all inter-service communication is immediately denied on both clusters simultaneously, without any pod restarts.

## Prerequisites

- Both clusters running with bookinfo deployed and accessible
- `generate-traffic.sh` running for Kiali visualization (recommended — shows traffic flow changes when deny-all is applied)
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Quick Run

```bash
./ossm/uc2-t1-verify.sh
```

## Manual Steps

### 1. Verify baseline — traffic flows normally

```bash
curl -s -o /dev/null -w "EAST: HTTP %{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
curl -s -o /dev/null -w "WEST: HTTP %{http_code}\n" http://bookinfo.apps.cluster-7rt9h.7rt9h.sandbox1900.opentlc.com/productpage
```

Expected: HTTP 200 on both.

### 2. Apply deny-all to root namespace on BOTH clusters

The root namespace (`istio-system`) is where mesh-wide policies apply. An AuthorizationPolicy with an empty `spec` matches all workloads and denies everything (no rules = no traffic allowed).

```bash
oc --context east apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system
spec: {}
EOF
```

```bash
oc --context west apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system
spec: {}
EOF
```

### 3. Verify lockdown — all traffic denied

```bash
curl -s -o /dev/null -w "EAST: HTTP %{http_code}\n" -m 10 http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
curl -s -o /dev/null -w "WEST: HTTP %{http_code}\n" -m 10 http://bookinfo.apps.cluster-7rt9h.7rt9h.sandbox1900.opentlc.com/productpage
```

Expected: connection failure or HTTP error (the gateway itself may also be denied depending on mesh enrollment).

Check ztunnel logs for explicit deny:

```bash
oc --context east logs -n ztunnel ds/ztunnel --tail=20 | grep -i "denied\|RBAC\|policy"
```

Expected: `connection closed due to policy rejection` messages.

### 4. Verify no pod restarts

```bash
oc --context east get pods -n bookinfo -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'
oc --context west get pods -n bookinfo -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'
```

All pods should show 0 restarts.

### 5. Check Kiali

- **Kiali graph**: observe traffic flow — denied connections stop generating edges
- Both clusters affected simultaneously

### 6. Cleanup — remove deny-all

```bash
oc --context east delete authorizationpolicy deny-all -n istio-system
oc --context west delete authorizationpolicy deny-all -n istio-system
```

### 7. Verify recovery

```bash
curl -s -o /dev/null -w "EAST: HTTP %{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
curl -s -o /dev/null -w "WEST: HTTP %{http_code}\n" http://bookinfo.apps.cluster-7rt9h.7rt9h.sandbox1900.opentlc.com/productpage
```

Expected: HTTP 200 on both — instant recovery, no restarts needed.

## Expected Results

| Phase | EAST | WEST | Pod Restarts |
|-------|------|------|-------------|
| Baseline | HTTP 200 | HTTP 200 | 0 |
| Deny-all applied | **Denied** | **Denied** | 0 |
| After cleanup | HTTP 200 | HTTP 200 | 0 |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| AuthorizationPolicy (deny-all) | Global zero-trust policy in root namespace | Yes — mesh security |
| ztunnel | Enforces deny at L4, rejects TCP connections | Yes — L4 data plane |
| istiod | Pushes global policy to all ztunnels | Yes — control plane |
| Root namespace (`istio-system`) | Policy propagation scope for the entire mesh | Yes — mesh config |
| Kiali | Shows traffic flow and denied connections across services | Yes — mesh observability |

## Key Takeaway

A single AuthorizationPolicy with an empty spec in the root namespace (`istio-system`) locks down the entire mesh instantly. In ambient mode, ztunnel enforces this at L4 — no sidecar restarts, no application changes. The lockdown is immediate and reversible in seconds. This is the foundation of a zero-trust security posture.
