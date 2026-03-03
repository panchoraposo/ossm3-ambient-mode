# Ambient Multi-Cluster Multi-Network — Test Log

## Context

As part of the OSSM 3.2 PoC (Multi-Primary, two OCP 4.20 clusters + ACM), we attempted to enable cross-cluster failover in ambient mode. The goal was to scale a bookinfo service to zero in EAST and have traffic automatically reroute to WEST via the east-west gateways (HBONE over mTLS, port 15008).

Reference guide followed: https://istio.io/latest/docs/ambient/install/multicluster/multi-primary_multi-network/

## Baseline State (before changes)

The environment was already configured with multi-cluster federation (from the Ansible playbook):

- Shared trust domain (`cluster.local`)
- Remote secrets exchanged between clusters
- East-west gateways deployed (using `gatewayClassName: istio-waypoint`)
- `meshNetworks` configured with gateway routes
- Bookinfo deployed in both clusters with namespaces enrolled in ambient mode

At this point, **service discovery worked** (istiod sees remote endpoints), but **no data plane path existed for cross-cluster traffic**.

## Step 1: Verify missing feature flags

Checked istiod environment variables:

```bash
oc --context east get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].spec.containers[0].env[*].name}'
oc --context west get pods -n istio-system -l app=istiod -o jsonpath='{.items[0].spec.containers[0].env[*].name}'
```

**Finding:** Only `PILOT_ENABLE_AMBIENT=true` was set. Both `AMBIENT_ENABLE_MULTI_NETWORK` and `AMBIENT_ENABLE_BAGGAGE` were missing. According to the Istio upstream docs, these are required for ambient multi-network.

## Step 2: Enable feature flags on istiod

Patched the Istio CR in both clusters to add the required environment variables:

```bash
# EAST
oc --context east patch istio default -n istio-system --type=merge -p '
spec:
  values:
    pilot:
      env:
        AMBIENT_ENABLE_MULTI_NETWORK: "true"
        AMBIENT_ENABLE_BAGGAGE: "true"
'

# WEST
oc --context west patch istio default -n istio-system --type=merge -p '
spec:
  values:
    pilot:
      env:
        AMBIENT_ENABLE_MULTI_NETWORK: "true"
        AMBIENT_ENABLE_BAGGAGE: "true"
'
```

The Sail Operator automatically recreated istiod pods in both clusters.

### Verification

```bash
oc --context east exec -n istio-system deploy/istiod -- env | grep AMBIENT
oc --context west exec -n istio-system deploy/istiod -- env | grep AMBIENT
```

**Result:** Both variables active in both clusters.

## Step 3: Check gateway discovery

```bash
# Check if istiod finds network gateways
oc --context east exec -n istio-system deploy/istiod -- pilot-discovery request GET /debug/networkz
```

**Finding:** `HBONEPort: 0` for all gateways, and istiod warnings:
- `"warn: no collection for NetworkGateways returned for cluster west"`
- `"warn: No network gateway found for network network2"`

The ambient multi-network code expected the east-west gateways to use `gatewayClassName: istio-east-west`, not `istio-waypoint`.

## Step 4: Check GatewayClass availability

```bash
oc --context east get gatewayclasses
```

**Finding:** The `istio-east-west` GatewayClass was **automatically created** when `AMBIENT_ENABLE_MULTI_NETWORK` was enabled. Controller: `istio.io/eastwest-controller`.

## Step 5: Update east-west gateways

Two changes were needed on the Gateway resources in both clusters:

1. Change `gatewayClassName` from `istio-waypoint` to `istio-east-west`
2. Add `topology.istio.io/network` label to the Gateway resource

```bash
# EAST — label and change class
oc --context east -n istio-system patch gateway istio-eastwestgateway \
  --type=merge -p '
metadata:
  labels:
    topology.istio.io/network: "network1"
spec:
  gatewayClassName: istio-east-west
'

# WEST — label and change class
oc --context west -n istio-system patch gateway istio-eastwestgateway \
  --type=merge -p '
metadata:
  labels:
    topology.istio.io/network: "network2"
spec:
  gatewayClassName: istio-east-west
'
```

### Verification

```bash
# Check ztunnel sees remote endpoints
oc --context east exec -n ztunnel ds/ztunnel -- ztunnel-redirect-inpod dump services 2>/dev/null | python3 -m json.tool | grep -A5 reviews
```

**Result:** ztunnel now showed remote endpoint for reviews as `SplitHorizonWorkload` via the WEST east-west gateway. The VIPs now included both networks:
- `network1/172.30.242.68` (local EAST)
- `network2/172.30.179.92` (remote WEST)

## Step 6: Test failover

Scaled reviews to zero in EAST to test cross-cluster failover:

```bash
oc --context east scale deployment reviews-v1 reviews-v2 reviews-v3 -n bookinfo --replicas=0
```

Then tested:

```bash
curl -s http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

## Result: FAILURE

ztunnel logged errors for ALL outbound connections:

```
warn  access  connection failed  dst.addr=172.30.242.68:9080  error="no service for target address: 172.30.242.68:9080"
```

**Root cause:** With `AMBIENT_ENABLE_MULTI_NETWORK` active, ztunnel changed its internal VIP format from `172.30.X.X` to `network1/172.30.X.X`. When application pods connected to ClusterIPs (e.g., `172.30.242.68`), ztunnel could not match them against its known services because the lookup used the bare IP while the index used the network-prefixed format.

This affected **ALL services**, not just reviews. The bookinfo productpage showed:
- "Error fetching product details"
- "Error fetching product reviews"

## Rollback

Reverted all changes to restore the environment:

```bash
# 1. Remove feature flags from Istio CR
for ctx in east west; do
  oc --context $ctx patch istio default -n istio-system --type=merge -p '
spec:
  values:
    pilot:
      env:
        AMBIENT_ENABLE_MULTI_NETWORK: "false"
        AMBIENT_ENABLE_BAGGAGE: "false"
'
done

# 2. Restore Gateway to original class
for ctx in east west; do
  oc --context $ctx -n istio-system patch gateway istio-eastwestgateway \
    --type=merge -p '
spec:
  gatewayClassName: istio-waypoint
'
done

# 3. Restore reviews replicas
oc --context east scale deployment reviews-v1 reviews-v2 reviews-v3 -n bookinfo --replicas=1

# 4. Rollout restart bookinfo to clear stale ztunnel state
for ctx in east west; do
  oc --context $ctx -n bookinfo rollout restart deployment
done
```

After rollback, all services returned to normal operation.

## Diagnosis

### Red Hat OSSM 3.2 Feature Support Matrix

The official feature support table explicitly classifies these capabilities:

| Ambient Mode Feature | OSSM 3.2 Status |
|---|---|
| Multi-Cluster - Multi-primary topology | **Developer Preview (DP)** |
| Multi-Cluster - Other topologies | **Not Available (NA)** |
| Waypoint: VirtualService | **Technology Preview (TP)** |

Source: https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/release_notes/ossm-release-notes-feature-support-tables

Red Hat defines Developer Preview as: *"Developer Preview features are not supported by Red Hat in any way and are not functionally complete or production-ready. Do not use Developer Preview features for production or business-critical workloads."*

Additionally, the "Supported configurations" page states: *"Configurations where all Service Mesh components are contained within a single OpenShift Container Platform cluster."*

Source: https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/installing/ossm-supported-platforms-configurations

### Istio Upstream References

- Istio 1.27 (OSSM 3.2 base): multi-network ambient introduced as **alpha**
  https://istio.io/latest/blog/2025/ambient-multicluster/
- Istio 1.29: multi-network ambient promoted to **beta**
  https://istio.io/latest/blog/2026/ambient-multinetwork-multicluster-beta/

### OSSM Team Response

The OSSM team confirmed:
> "Multi-cluster (multi-primary multi-network to be specific) with ambient mode is 'dev preview' (so not supported but you can try it) in 3.2 and we will update it to 'tech preview' in 3.3 (meaning, we're testing it ourselves and will have some OSSM docs soon). Hopefully at least partial GA later this year."

## Summary

| What worked | What failed |
|---|---|
| Feature flags activated correctly in istiod | VIP lookup broken by network-prefixed format |
| `istio-east-west` GatewayClass created automatically | All outbound service resolution failed |
| ztunnel recognized remote endpoints as `SplitHorizonWorkload` | Not limited to cross-cluster — broke ALL traffic |
| Gateway discovery found remote east-west gateways | Required full rollback to restore |

### Conclusion

The control plane federation works (discovery, remote secrets, shared trust), but the data plane for cross-cluster traffic in ambient mode is not functional in OSSM 3.2 / Istio 1.27. This is consistent with the Developer Preview classification. The OSSM team expects Tech Preview in 3.3 and partial GA later in 2026.
