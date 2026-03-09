# UC4-T2: The Kiali "Global Map" Reveal

## Objective

Demonstrate that Kiali provides a **unified multi-cluster service graph** — a single pane of glass showing all services across federated clusters. Services deployed in WEST2 automatically appear in the graph connected to callers in EAST2, with cluster-level grouping and live traffic animation. No manual registration or service catalog configuration is required.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`, `acm2`
- Istio 1.29 Multi-Primary federation active (remote secrets configured)
- bookinfo application deployed in namespace `bookinfo` on both clusters
- Kiali accessible on `acm2` (centralized observability hub)
- Traffic flowing to populate the graph (`generate-traffic.sh` or UC4-T1)

## Quick Run

```bash
./istio/uc4-t2-verify.sh
```

## What to Show in Kiali

### 1. Automatic Service Discovery

Open the **Graph** view in Kiali and select namespace `bookinfo`:

- All services from **both clusters** appear as nodes in the graph
- `reviews`, `ratings`, `details` in WEST2 are automatically discovered — no manual registration
- istiod's federated endpoint registry (via remote secrets) feeds Kiali with the complete topology

### 2. Multi-Cluster Visualization

In the graph, look for the **cluster grouping boxes**:

- **EAST2 box**: contains `productpage`, `reviews`, `ratings`, `details` (local instances)
- **WEST2 box**: contains `productpage`, `reviews`, `ratings`, `details` (remote instances)
- Each box represents a physical cluster boundary
- Edges crossing box boundaries represent cross-cluster HBONE traffic

### 3. Traffic Animation

Enable **Traffic Animation** in the graph display options:

- Animated dots flow along edges showing the live direction and volume of requests
- Cross-cluster edges show traffic flowing through the East-West Gateway
- Response time and success rate labels appear on edges when traffic is active

### 4. Graph Options

Recommended Kiali graph settings for the demo:

| Setting | Value |
|---|---|
| Graph type | Versioned app |
| Namespaces | bookinfo |
| Display | Traffic Animation ON |
| Display | Security ON (shows mTLS padlock) |
| Traffic | Request Rate |

## Manual Steps

### 1. Ensure traffic is flowing

```bash
./generate-traffic.sh
```

Or generate a burst manually:

```bash
EAST_URL="http://$(oc --context east2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"
WEST_URL="http://$(oc --context west2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"
for i in $(seq 1 20); do curl -s -o /dev/null "$EAST_URL"; curl -s -o /dev/null "$WEST_URL"; sleep 0.5; done
```

### 2. Verify Kiali sees both clusters

```bash
KIALI_HOST=$(oc --context acm2 get route kiali -n istio-system -o jsonpath='{.spec.host}')
KIALI_TOKEN=$(oc --context acm2 create token kiali-service-account -n istio-system)

# Clusters discovered
curl -sk "https://${KIALI_HOST}/api/status" \
  -H "Authorization: Bearer ${KIALI_TOKEN}" | python3 -m json.tool
```

Expected: `externalServices` lists `Kubernetes-east2`, `Kubernetes-west2`, `Kubernetes-acm2`.

### 3. Verify graph has nodes from both clusters

```bash
curl -sk "https://${KIALI_HOST}/api/namespaces/graph?namespaces=bookinfo&graphType=versionedApp&duration=120s&injectServiceNodes=true" \
  -H "Authorization: Bearer ${KIALI_TOKEN}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
nodes = data.get('elements',{}).get('nodes',[])
edges = data.get('elements',{}).get('edges',[])
clusters = set()
for n in nodes:
    clusters.add(n.get('data',{}).get('cluster','?'))
print(f'Clusters: {clusters}')
print(f'Nodes: {len(nodes)}, Edges: {len(edges)}')
"
```

Expected: `Clusters: {'east2', 'west2'}`, nodes from both clusters, edges showing active traffic.

### 4. Open the Kiali UI

```bash
oc --context acm2 get route kiali -n istio-system -o jsonpath='{.spec.host}'
```

Navigate to: `https://<kiali-host>/kiali/console/graph/namespaces/?namespaces=bookinfo&graphType=versionedApp`

## Expected Results

| Verification | Expected |
|---|---|
| Kiali status | Running (v2.17.x) |
| Clusters discovered | `east2`, `west2`, `acm2` |
| Graph nodes | Services from both clusters (productpage, reviews, ratings, details x2) |
| Graph edges | Active edges with request rate when traffic flows |
| Cluster boxes | Visual grouping by cluster in the graph |
| Traffic Animation | Animated dots showing live request flow |
| mTLS padlock | Shown on edges (Security display ON) |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| Kiali (on ACM2) | Unified multi-cluster service graph — single pane of glass | Yes — centralized observability |
| istiod | Feeds Kiali with federated service topology via remote secrets | Yes — control plane discovery |
| promxy (on ACM2) | Fans out Prometheus queries to both clusters for metrics | Yes — centralized metrics |
| ztunnel | Generates L4 telemetry (TCP metrics) consumed by Prometheus | Yes — data plane telemetry |
| Remote secrets | Allow Kiali to discover and query services across clusters | Yes — multi-cluster access |

## Key Takeaway

Kiali transforms the mesh's internal service registry into a **visual global map**. Every service, regardless of which cluster hosts it, appears automatically in the graph — with traffic animation, response times, and mTLS verification. There is no service catalog to maintain, no manual topology configuration, and no custom dashboards to build. The mesh provides the data; Kiali renders the map.
