# UC1-T5: Control Plane Independence (Multi-Primary)

## Objective

Prove that the **Multi-Primary topology eliminates single point of failure** risk. When istiod in one cluster goes down, the other cluster continues to manage local traffic and enforce security policies independently. Even the cluster that lost its control plane keeps serving traffic — because the data plane (ztunnel) operates with cached configuration.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`, `acm2`
- Istio 1.29 Multi-Primary federation active (remote secrets configured)
- bookinfo application deployed in namespace `bookinfo` on both clusters
- Ambient mode enabled on `bookinfo` namespace
- `generate-traffic.sh` running (recommended — shows continued flow in Kiali)

## Quick Run

```bash
./istio/uc1-t5-verify.sh
```

## Architecture

### Multi-Primary: Independent control planes

```
  EAST2                                    WEST2
  ─────                                    ─────
  ┌──────────┐                             ┌──────────┐
  │  istiod   │ ← independent              │  istiod   │ ← independent
  └─────┬────┘                             └─────┬────┘
        │ config push                            │ config push
        ▼                                        ▼
  ┌──────────┐                             ┌──────────┐
  │  ztunnel  │ ← cached config            │  ztunnel  │ ← cached config
  └──────────┘                             └──────────┘
        │                                        │
  ┌──────────┐                             ┌──────────┐
  │ bookinfo  │                            │ bookinfo  │
  └──────────┘                             └──────────┘

  If istiod EAST2 goes down:
  ✓ ztunnel EAST2 keeps routing with cached config
  ✓ mTLS remains active (certificates are cached)
  ✓ WEST2 is completely unaffected
  ✗ No new config updates on EAST2 until istiod recovers
```

## Manual Steps

### 1. Verify initial state — istiod running in both clusters

```bash
oc --context east2 get pods -n istio-system -l app=istiod
oc --context west2 get pods -n istio-system -l app=istiod
```

Expected: `1/1 Running` on both.

Baseline traffic test:

```bash
EAST_URL="http://$(oc --context east2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"
WEST_URL="http://$(oc --context west2 get route bookinfo-gateway -n bookinfo -o jsonpath='{.spec.host}')/productpage"
curl -s -o /dev/null -w "%{http_code}" "$EAST_URL"
curl -s -o /dev/null -w "%{http_code}" "$WEST_URL"
```

Expected: `200` from both.

### 2. Simulate control plane failure in EAST2

```bash
oc --context east2 scale deployment istiod -n istio-system --replicas=0
```

Verify istiod is gone:

```bash
oc --context east2 get pods -n istio-system -l app=istiod
# Expected: No resources found
```

### 3. Verify traffic keeps flowing

```bash
curl -s -o /dev/null -w "%{http_code}" "$EAST_URL"   # Expected: 200
curl -s -o /dev/null -w "%{http_code}" "$WEST_URL"   # Expected: 200
```

Both should return `200`. The ztunnel on EAST2 continues routing with its cached configuration. WEST2 is completely unaffected — its istiod is independent.

Check Kiali — traffic graph should show normal flow on both clusters.

### 4. Restore istiod in EAST2

```bash
oc --context east2 scale deployment istiod -n istio-system --replicas=1
```

```bash
oc --context east2 get pods -n istio-system -l app=istiod
# Expected: 1/1 Running
```

## Expected Results

| Phase | istiod EAST2 | EAST2 traffic | WEST2 traffic |
|---|---|---|---|
| Baseline | Running (1/1) | HTTP 200 | HTTP 200 |
| istiod down | **0 pods** | **HTTP 200** (cached) | **HTTP 200** (independent) |
| Restored | Running (1/1) | HTTP 200 | HTTP 200 |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| istiod (per cluster) | Independent control plane — pushes config to ztunnel | Yes — control plane |
| Multi-Primary topology | Each cluster has its own istiod — no single point of failure | Yes — mesh architecture |
| ztunnel | Continues routing and mTLS with cached config when istiod is absent | Yes — L4 data plane |
| Cached configuration | ztunnel keeps last-known routing rules and certificates in memory | Yes — data plane resilience |
| WEST2 independence | WEST2 istiod and ztunnel operate without any dependency on EAST2 | Yes — fault isolation |

## Key Takeaway

In ambient mode, the data plane (ztunnel) operates independently from the control plane (istiod). Once configured, ztunnel keeps its routing rules, mTLS certificates, and security policies cached in memory. Losing istiod means no new configuration updates can be pushed — but existing traffic routing, mTLS encryption, and policies remain fully active. The Multi-Primary topology ensures that one cluster's control plane failure has zero impact on the other cluster.
