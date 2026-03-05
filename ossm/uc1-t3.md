# UC1-T3: Multi-Primary Federation & Discovery

## Objective

Verify that both clusters share a trust domain, exchange remote secrets for mutual API access, and automatically discover each other's services. Kiali must present both clusters and their services in the service graph.

## Prerequisites

- Both clusters running with bookinfo deployed (verified in UC1-T2)
- `generate-traffic.sh` running
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Quick Run

```bash
./ossm/uc1-t3-verify.sh
```

## Manual Steps

### 1. Verify shared trust domain

Both clusters must use the same SPIFFE trust domain so mTLS identities are mutually recognized.

```bash
oc --context east logs -n ztunnel ds/ztunnel --tail=5 | grep -o 'spiffe://[^"]*' | head -1
oc --context west logs -n ztunnel ds/ztunnel --tail=5 | grep -o 'spiffe://[^"]*' | head -1
```

Expected: both show `spiffe://cluster.local/...` (same trust domain `cluster.local`).

### 2. Verify multi-cluster enabled with cluster IDs

```bash
oc --context east get istio default -n istio-system -o jsonpath='{.spec.values.global.multiCluster}'
oc --context west get istio default -n istio-system -o jsonpath='{.spec.values.global.multiCluster}'
```

Expected:
- EAST: `{"clusterName":"east","enabled":true}`
- WEST: `{"clusterName":"west","enabled":true}`

### 3. Verify remote secrets (cross-cluster API access)

Each cluster holds a remote secret with the kubeconfig of the other, allowing istiod to discover remote endpoints.

```bash
oc --context east get secrets -n istio-system -l istio/multiCluster=true
oc --context west get secrets -n istio-system -l istio/multiCluster=true
```

Expected:
- EAST has `istio-remote-secret-west`
- WEST has `istio-remote-secret-east`

### 4. Verify network topology

```bash
oc --context east get ns istio-system -o jsonpath='{.metadata.labels.topology\.istio\.io/network}'
oc --context west get ns istio-system -o jsonpath='{.metadata.labels.topology\.istio\.io/network}'
```

Expected: EAST = `network1`, WEST = `network2`.

### 5. Verify east-west gateways

The east-west gateways enable cross-network traffic between clusters.

```bash
oc --context east get pods -n istio-system | grep eastwest
oc --context west get pods -n istio-system | grep eastwest
```

Expected: `Running` in both clusters.

### 6. Verify automatic service discovery

Services labeled `istio.io/global=true` are automatically discovered across clusters.

```bash
oc --context east get svc -n bookinfo -l istio.io/global=true -o custom-columns='NAME:.metadata.name'
oc --context west get svc -n bookinfo -l istio.io/global=true -o custom-columns='NAME:.metadata.name'
```

Expected: `details`, `productpage`, `ratings`, `reviews` on both clusters.

### 7. Verify in Kiali

Open Kiali from the ACM console:

https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

- Select namespace `bookinfo`
- Both clusters (EAST and WEST) should appear in the graph
- Services from both clusters should be visible in the service list
- Traffic edges should show cross-cluster communication when traffic is flowing

## Expected Results

| Component | EAST | WEST |
|-----------|------|------|
| Trust domain | `cluster.local` | `cluster.local` |
| Cluster ID | `east` | `west` |
| Multi-cluster enabled | `true` | `true` |
| Remote secret | `istio-remote-secret-west` | `istio-remote-secret-east` |
| Network | `network1` | `network2` |
| East-west gateway | Running | Running |
| Services discoverable | details, productpage, ratings, reviews | details, productpage, ratings, reviews |
| Kiali graph | Shows both clusters | Shows both clusters |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| Shared trust domain (`cluster.local`) | Unified identity across clusters | Yes — mTLS / SPIFFE |
| Remote secrets | Cross-cluster API access for istiod | Yes — control plane federation |
| istiod (per cluster) | Discovers remote endpoints, pushes config | Yes — control plane |
| East-west gateways | Cross-network connectivity (HBONE) | Yes — data plane |
| Kiali (ACM) | Unified visualization of both clusters | Yes — mesh observability |
| `istio.io/global=true` label | Marks services for cross-cluster discovery | Yes — service discovery |

## Key Takeaway

The Multi-Primary topology with shared trust domain (`cluster.local`) enables automatic service discovery without manual DNS or routing configuration. Each istiod instance uses remote secrets to query the other cluster's API server, discovering endpoints and pushing them to the local data plane. Kiali provides a unified view of both clusters from the ACM hub.
