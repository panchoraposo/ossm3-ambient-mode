## Use case: Cross-cluster failover (Ambient multi-cluster)

### Goal

When `reviews`/`ratings` are unavailable in `east2`, requests originating in `east2` should fail over and be served by `west2`.

### Implementation (what we deploy)

- **Multi-cluster + multi-network connectivity**:
  - Each cluster runs its own Istio control plane (multi-primary).
  - Remote cluster discovery is enabled via `istioctl create-remote-secret` (east↔west).
  - A dedicated **east-west gateway** is deployed using `GatewayClass istio-east-west` and exposed via a **LoadBalancer** on port `15008` (HBONE).
  - `meshNetworks` is configured so `network1` and `network2` know which gateway address/port to use for cross-network routing.

- **Global service visibility**:
  - Bookinfo services are labeled `istio.io/global: "true"` so they are visible across clusters (Istio service scope config selects these).

- **Failover policy** (`DestinationRule`) for:
  - `reviews.bookinfo.svc.cluster.local`
  - `ratings.bookinfo.svc.cluster.local`

Key points:
- `outlierDetection` ejects unhealthy endpoints quickly.
- `localityLbSetting.failoverPriority: [topology.istio.io/cluster]` prefers same-cluster endpoints, and fails over to the other cluster when local endpoints disappear.

### How we test it (script + expected results)

Script:

```bash
CTX_EAST=east2 CTX_WEST=west2 ./scripts/istio129/demo-failover.sh
```

What the script does:
- Ensures `demo-curl` exists in `bookinfo` on `east2`
- Cleans traffic-shifting config (`VirtualService reviews-split`) to avoid interference
- Applies failover `DestinationRule`s on both clusters
- Verifies baseline requests served by `east2`
- Scales down `reviews`/`ratings` on `east2` to 0 and waits until pods are gone
- Verifies that requests from `east2` are now served by `west2`
- Restores replicas on `east2`

For a Kiali-friendly run (clear “before” and “after” windows):

```bash
CTX_EAST=east2 CTX_WEST=west2 DEMO_MODE=kiali PRE_HOLD_SECONDS=90 POST_HOLD_SECONDS=180 \
  ./scripts/istio129/demo-failover.sh
```

Expected outcome:
- Before scaling down: `clustername=east2`
- After scaling down: `clustername=west2` (and no 503s)

### What to look at in Kiali

- Kiali `Graph` → Namespace `bookinfo`
- Time range: `Last 10m` (recommended)
- During “baseline” window: traffic should land on `east2` workloads
- During “after failover” window: traffic should land on `west2` workloads
- Ambient note:
  - Ensure the graph traffic selectors include **Waypoint (L7)** for HTTP traffic, otherwise the graph can look empty.

