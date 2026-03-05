# UC1-T5: Control Plane Independence

## Objective

Prove that the Multi-Primary topology eliminates single point of failure risk. Stopping istiod in one cluster does not affect the other cluster or local traffic.

## Quick Run

```bash
./ossm/uc1-t5-verify.sh
```

## Prerequisites

- Both clusters (EAST and WEST) running with bookinfo deployed
- `generate-traffic.sh` running to produce continuous traffic for Kiali visualization
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Steps

### 1. Verify initial state

```bash
oc --context east get pods -n istio-system -l app=istiod
oc --context west get pods -n istio-system -l app=istiod
```

Both should show `1/1 Running`.

### 2. Simulate control plane failure in EAST

```bash
oc --context east scale deployment istiod -n istio-system --replicas=0
```

Wait a few seconds and confirm istiod is gone:

```bash
oc --context east get pods -n istio-system -l app=istiod
# Expected: No resources found
```

### 3. Verify traffic keeps flowing

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
curl -s -o /dev/null -w "%{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Both should return `200`. Check Kiali on WEST — traffic graph should show normal flow.

Traffic Graph: https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

### 4. Restore istiod in EAST

```bash
oc --context east scale deployment istiod -n istio-system --replicas=1
```

Verify it comes back:

```bash
oc --context east get pods -n istio-system -l app=istiod
# Expected: 1/1 Running
```

## Expected Results


| Phase       | istiod EAST | EAST traffic | WEST traffic |
| ----------- | ----------- | ------------ | ------------ |
| Before      | Running     | 200          | 200          |
| istiod down | **0 pods**  | **200**      | **200**      |
| Restored    | Running     | 200          | 200          |


## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| istiod (per cluster) | Independent control plane, pushes config to ztunnel | Yes — control plane |
| ztunnel | Continues routing and mTLS with cached config | Yes — L4 data plane |
| Waypoint proxies | Continue L7 policies with cached config | Yes — L7 data plane |
| Multi-Primary topology | Each cluster operates independently | Yes — mesh architecture |
| Kiali | Shows traffic still flowing during failure | Yes — mesh observability |

## Key Takeaway

In ambient mode, the data plane (ztunnel + waypoint proxies) operates independently from the control plane (istiod). Once configured, ztunnel and waypoints keep their last-known configuration in memory. Losing istiod only means no new configuration updates — existing traffic routing, mTLS, and policies remain active.