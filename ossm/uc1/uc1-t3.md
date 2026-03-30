# UC1-T3: Multi-Primary Federation & Discovery

## Objective

Verify that both clusters share a trust domain, exchange remote secrets for mutual API access, and automatically discover each other's services. Kiali must present both clusters and their services in the service graph.

## Prerequisites

- Both clusters running with bookinfo deployed (verified in UC1-T2)
- `generate-traffic.sh` running
- Kiali open (OSSMC via [ACM console](https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph))

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

### 2. Verify remote secrets (cross-cluster API access)

Each cluster holds a remote secret with the kubeconfig of the other, allowing istiod to discover remote endpoints.

```bash
oc --context east get secrets -n istio-system -l istio/multiCluster=true
oc --context west get secrets -n istio-system -l istio/multiCluster=true
```

Expected:
- EAST has `istio-remote-secret-west`
- WEST has `istio-remote-secret-east`

### 3. Verify multi-cluster enabled with cluster IDs

```bash
oc --context east get istio default -n istio-system -o jsonpath='{.spec.values.global.multiCluster}'
oc --context west get istio default -n istio-system -o jsonpath='{.spec.values.global.multiCluster}'
```

Expected:
- EAST: `{"clusterName":"east","enabled":true}`
- WEST: `{"clusterName":"west","enabled":true}`

### 4. Verify east-west gateways

The east-west gateways allow each istiod to reach the remote cluster's API server for service discovery. They handle **control plane** connectivity, not user data plane traffic.

```bash
oc --context east get pods -n istio-system | grep eastwest
oc --context west get pods -n istio-system | grep eastwest
```

Expected: `Running` in both clusters.

### 5. Verify automatic service discovery

In multi-primary with remote secrets, istiod discovers all services from the remote cluster automatically — no special labels needed.

```bash
oc --context east get svc -n bookinfo
oc --context west get svc -n bookinfo
```

Expected: `details`, `productpage`, `ratings`, `reviews` on both clusters.

### 6. Verify in Kiali

Open Kiali from the ACM console:

https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

- Select namespace `bookinfo`
- Both clusters (EAST and WEST) should appear in the graph
- Services from both clusters are discovered and visible

## Expected Results

| Component | EAST | WEST |
|-----------|------|------|
| Trust domain | `cluster.local` | `cluster.local` |
| Cluster ID | `east` | `west` |
| Multi-cluster enabled | `true` | `true` |
| Remote secret | `istio-remote-secret-west` | `istio-remote-secret-east` |
| East-west gateway | Running | Running |
| Services discoverable | details, productpage, ratings, reviews | details, productpage, ratings, reviews |
| Kiali graph | Shows both clusters | Shows both clusters |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| Shared trust domain (`cluster.local`) | Unified identity across clusters | Yes — mTLS / SPIFFE |
| Remote secrets | Cross-cluster API access for istiod | Yes — control plane federation |
| istiod (per cluster) | Discovers remote endpoints, pushes config | Yes — control plane |
| East-west gateways | Cross-cluster connectivity for control plane federation | Yes — control plane |
| Kiali (ACM) | Unified visualization of both clusters | Yes — mesh observability |
| Remote secrets + istiod | Automatic cross-cluster service discovery | Yes — service discovery |

## Key Takeaway

The Multi-Primary topology with shared trust domain (`cluster.local`) enables automatic service discovery without manual DNS or routing configuration. Each istiod instance uses remote secrets to query the other cluster's API server, discovering endpoints and pushing them to the local data plane. Kiali provides a unified view of both clusters from the ACM hub.
