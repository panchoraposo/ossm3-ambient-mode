## Use case: L7 traffic shifting (Ambient waypoint)

### Goal

Shift L7 traffic for the `reviews` service between `reviews-v1` and `reviews-v2` while keeping `reviews-v3` at 0% (no traffic).

### Implementation (what we deploy)

- **Waypoint enforcement (Ambient)**:
  - `bookinfo` uses per-service waypoints (ex: `reviews-waypoint`).
  - The `reviews` workloads are bound to the waypoint via:
    - Service label `istio.io/use-waypoint=reviews-waypoint`
    - Workload labels `istio.io/use-waypoint=reviews-waypoint` (patched by the script). This is important on OpenShift where DNAT can make ztunnel observe “workload IP” and bypass service-level binding.

- **DestinationRule with subsets** (`reviews.bookinfo.svc.cluster.local`):
  - Defines subsets `v1`, `v2`, `v3` mapped to workload label `version: v1|v2|v3`.
  - Uses `localityLbSetting.failoverPriority: [topology.istio.io/cluster]` to keep traffic local (avoid cross-cluster effects during the shifting demo).

- **VirtualService**:
  - `VirtualService reviews-split` routes to subsets `v1` and `v2` with configurable weights.

### How we test it (script + expected results)

Script:

```bash
CTX_EAST=east2 ./scripts/istio129/demo-traffic-shift.sh
```

What the script does:
- Ensures `demo-curl` exists in `bookinfo`
- Ensures `reviews-v1` and `reviews-v2` are running
- Enforces waypoint binding for the `reviews` workloads
- Applies `DestinationRule` + `VirtualService` and validates the observed distribution

For a Kiali-friendly run (holds each phase for visualization):

```bash
CTX_EAST=east2 DEMO_MODE=kiali HOLD_SECONDS_1=180 HOLD_SECONDS_2=180 HOLD_SECONDS_3=180 \
  ./scripts/istio129/demo-traffic-shift.sh
```

Expected outcome:
- Traffic split matches the phase (roughly 90/10 → 50/50 → 0/100)
- **No traffic** reaches `reviews-v3`

### What to look at in Kiali

- Kiali `Graph` → Namespace `bookinfo`
- Time range: `Last 5m` / `Last 10m`
- Workload graph: look for:
  - `reviews-waypoint` node
  - edges `reviews-waypoint → reviews-v1` and `reviews-waypoint → reviews-v2`
  - edge percentages/rates changing per phase
- Ambient note:
  - Ensure the graph traffic selectors include **Waypoint (L7)** (telemetry is `istio_requests_total{reporter="waypoint"}` in Ambient).

