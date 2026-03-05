## Istio community 1.29 (Ambient) — Multi-cluster demo on `east2` + `west2`

This branch sets up the demo on **two new clusters** using **Istio upstream 1.29** (not OSSM), with kubeconfig contexts:

- `east2`
- `west2`
- (optional) `acm2` for GitOps/observability, not required for the core demo

### Why a separate install path

OSSM and upstream Istio are not meant to be installed side-by-side on the same clusters (CRDs, CNI and ztunnel overlap). This path assumes **clean clusters** for the upstream test.

### Prerequisites

- `oc` logged into both clusters
- kubeconfig contexts: `east2`, `west2`
- Tools on your machine:
  - `kubectl`, `oc`, `curl`, `tar`, `openssl`

### Install (one command)

```bash
CTX_EAST=east2 CTX_WEST=west2 ISTIO_VERSION=1.29.0 ./scripts/istio129/install.sh
```

Notes:
- `ISTIO_VERSION` can be overridden (for example `1.29.2`).
- The script downloads a matching `istioctl` into `.cache/istio/` (not committed).
- The script generates a shared `cacerts` and installs it on both clusters.

### Deploy Bookinfo (required for both use cases)

```bash
CTX_EAST=east2 CTX_WEST=west2 ./scripts/istio129/deploy-bookinfo.sh
```

What this does:
- Deploys Bookinfo on **both** clusters in namespace `bookinfo`
- Creates waypoints (L7) and grants the required OpenShift `anyuid` SCC to waypoint service accounts
- Sets `CLUSTER_NAME` env vars in `reviews`/`ratings` so responses include which cluster served the request

### Demo scripts

#### 1) Traffic shifting (VirtualService via waypoint)

```bash
CTX_EAST=east2 ./scripts/istio129/demo-traffic-shift.sh
```

This applies a `VirtualService` for `reviews` (subsets `v1`/`v2`) and shows the distribution between `reviews-v1` and `reviews-v2`.

Implementation + test details: `docs/ISTIO_1_29_USE_CASE_TRAFFIC_SHIFT.md`

#### 2) Cross-cluster failover (reviews/ratings)

```bash
CTX_EAST=east2 CTX_WEST=west2 ./scripts/istio129/demo-failover.sh
```

This scales `reviews`/`ratings` to 0 on `east2` and validates that requests from `east2` start being served by `west2`.

Implementation + test details: `docs/ISTIO_1_29_USE_CASE_FAILOVER.md`

### What to look at in Kiali (quick steps)

Open Kiali (hub `acm2`) and focus on the `bookinfo` namespace.

1) **Select namespace**: `Graph` → Namespace `bookinfo`
2) **Time range**: top bar → choose `Last 5m` (or `Last 10m` if you run longer holds)
3) **Graph type**: `Workload graph` (best for seeing `reviews-waypoint` → `reviews-v1/v2`)
4) **Show traffic**:
   - Enable request rates / traffic animation if available
   - Enable edge labels with `%` / request rate if available
5) **Ambient-specific**:
   - Ensure the graph **traffic selectors include Waypoint (L7)**. In Ambient, HTTP telemetry is often reported with `reporter="waypoint"`.
   - If you only select source/destination traffic, the graph can look empty even while traffic is flowing.

#### View use case 1 in Kiali (traffic shifting)

Run the demo in “kiali mode” so it holds each phase long enough to observe:

```bash
CTX_EAST=east2 DEMO_MODE=kiali HOLD_SECONDS_1=60 HOLD_SECONDS_2=60 HOLD_SECONDS_3=60 \
  ./scripts/istio129/demo-traffic-shift.sh
```

What you should see:
- A node for `reviews-waypoint`
- Outgoing edges from `reviews-waypoint` to `reviews-v1` and `reviews-v2`
- The edge split should match each phase (roughly 90/10 → 50/50 → 0/100)

#### View use case 2 in Kiali (failover)

Run the demo in “kiali mode” so you have a clear *before* and *after* window:

```bash
CTX_EAST=east2 CTX_WEST=west2 DEMO_MODE=kiali PRE_HOLD_SECONDS=45 POST_HOLD_SECONDS=90 \
  ./scripts/istio129/demo-failover.sh
```

What you should see:
- **Before** scaling down: traffic served by `east2` (edges should stay on the east side)
- **After** scaling down: traffic served by `west2` (you should see requests landing on `west2` workloads)

#### Run both (one command, optional)

```bash
CTX_EAST=east2 CTX_WEST=west2 ./scripts/istio129/validate-use-cases.sh
```

### Troubleshooting notes (common gotchas)

- **GitOps reverting scale-down (failover demo)**: if `reviews`/`ratings` immediately scale back up on `east2`, pause your ArgoCD app or add `ignoreDifferences` for replica count before running `demo-failover.sh`.
- **Traffic shifting has no effect**: ensure the namespace is ambient-enrolled and that workloads are bound to the waypoint. The script `demo-traffic-shift.sh` enforces this by labeling/paching `reviews-v1/v2/v3` with `istio.io/use-waypoint=reviews-waypoint`.

### Optional: central observability on `acm2`

If you also want to set up **observability on the hub `acm2`** (Kiali multi-cluster, promxy, etc.) for `east2`/`west2`, use:

```bash
CTX_ACM=acm2 CTX_EAST=east2 CTX_WEST=west2 ./scripts/istio129/install-acm2-observability.sh
```

#### Why you might see "no traffic" in Kiali

Kiali graphs are based on **Prometheus metrics** (for example `istio_requests_total`). If the Prometheus backend has **no Istio metrics**, Kiali will look "empty" even if requests are happening.

For this demo, the most reliable path is to use the **Istio Prometheus addon** on each managed cluster and point `promxy` at those Prometheus endpoints.

#### Recommended setup (Prometheus addon per cluster + promxy on hub)

1) Install Prometheus addon on `east2` and `west2` and expose it via an OpenShift Route:

```bash
CTX_EAST=east2 CTX_WEST=west2 ISTIO_VERSION=1.29.0 ./scripts/istio129/install-prometheus-addon.sh
```

2) Enable scraping of waypoint/gateway metrics (adds `prometheus.io/*` annotations to Bookinfo waypoints and the Bookinfo gateway):

```bash
CTX_EAST=east2 CTX_WEST=west2 ./scripts/istio129/enable-istio-prometheus-scrape.sh
```

3) Install / reconfigure hub observability so `promxy` uses the Prometheus Routes (instead of Thanos):

```bash
CTX_ACM=acm2 CTX_EAST=east2 CTX_WEST=west2 \
  PROM_BACKEND_NS=istio-system PROM_BACKEND_SVC=prometheus \
  ./scripts/istio129/install-acm2-observability.sh
```

4) If you changed `promxy-upstreams`, restart promxy so it re-renders its config:

```bash
oc --context acm2 -n istio-system rollout restart deploy/promxy
```

You can sanity-check that metrics exist via promxy:

```bash
PROMXY_HOST="$(oc --context acm2 -n istio-system get route promxy -o jsonpath='{.spec.host}')"
curl -sk "https://${PROMXY_HOST}/api/v1/query" --data-urlencode 'query=count(istio_requests_total)'
```

