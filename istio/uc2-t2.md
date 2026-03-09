# UC2-T2: ServiceAccount-Based Enablement (Cross-Namespace Identity)

## Objective

Demonstrate that the mesh enforces access control based on **SPIFFE identities** (ServiceAccount-based). A service in a different namespace can only access `reviews` in `bookinfo` if its ServiceAccount is explicitly authorized — regardless of which cluster or namespace the request originates from.

## Prerequisites

- Clusters accessible with contexts `east2`, `west2`
- Istio 1.29 Multi-Primary federation active
- bookinfo application deployed in namespace `bookinfo` on EAST2
- Namespace `bookinfo-external` deployed on EAST2 with ambient mode enabled (see setup below)
- `generate-traffic.sh` running (optional, for Kiali visualization)

## Setup: `bookinfo-external` Namespace

The `bookinfo-external` namespace contains a copy of `productpage` with `SERVICES_DOMAIN=bookinfo.svc.cluster.local`, which calls `reviews`, `details`, and `ratings` in the `bookinfo` namespace. It uses a different ServiceAccount (`bookinfo-external-productpage`), giving it a distinct SPIFFE identity:

```
bookinfo:          spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage
bookinfo-external: spiffe://cluster.local/ns/bookinfo-external/sa/bookinfo-external-productpage
```

The verification script deploys `bookinfo-external` automatically if it does not exist.

## Quick Run

```bash
./istio/uc2-t2-verify.sh
```

## Manual Steps

### 1. Verify baseline — both namespaces access reviews

```bash
# Original bookinfo
curl -s -m 15 "http://$(oc --context east2 get route bookinfo-gateway -n bookinfo \
  -o jsonpath='{.spec.host}')/productpage" | grep -oE "Book Details|Book Reviews"

# External bookinfo
curl -s -m 15 "http://$(oc --context east2 get route bookinfo-external -n bookinfo-external \
  -o jsonpath='{.spec.host}')/productpage" | grep -oE "Book Details|Book Reviews"
```

Expected: both show `Book Details` and `Book Reviews`.

### 2. Deploy reviews-waypoint and apply DENY policy

Deploy a waypoint proxy for reviews (required for L7 AuthorizationPolicy with `targetRefs`):

```bash
oc --context east2 apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: reviews-waypoint
  namespace: bookinfo
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
EOF

oc --context east2 label svc reviews -n bookinfo istio.io/use-waypoint=reviews-waypoint --overwrite
```

Apply the DENY policy targeting traffic from `bookinfo-external`:

```bash
oc --context east2 apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-deny-external
  namespace: bookinfo
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: reviews
  action: DENY
  rules:
  - from:
    - source:
        namespaces:
        - bookinfo-external
EOF
```

Expected after propagation:
- **Original bookinfo**: Book Details + Book Reviews (works)
- **External bookinfo**: Book Details OK, **Error fetching product reviews** (denied)

### 3. Switch to ALLOW by SPIFFE identity

Remove the DENY and apply an ALLOW that authorizes both ServiceAccounts explicitly:

```bash
oc --context east2 delete authorizationpolicy reviews-deny-external -n bookinfo

oc --context east2 apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: reviews-allow-by-identity
  namespace: bookinfo
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: reviews
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - "cluster.local/ns/bookinfo/sa/bookinfo-productpage"
        - "cluster.local/ns/bookinfo-external/sa/bookinfo-external-productpage"
EOF
```

Expected: both Routes return Book Details + Book Reviews (both identities authorized).

### 4. Cleanup

```bash
oc --context east2 delete authorizationpolicy reviews-allow-by-identity -n bookinfo
oc --context east2 label svc reviews -n bookinfo istio.io/use-waypoint-
oc --context east2 delete gateway reviews-waypoint -n bookinfo
```

## Expected Results

| Phase | Original bookinfo | External bookinfo |
|---|---|---|
| No policy | Details + Reviews OK | Details + Reviews OK |
| DENY external namespace | Details + Reviews OK | Details OK, **Reviews DENIED** |
| ALLOW both SAs | Details + Reviews OK | Details + Reviews OK |
| After cleanup | Details + Reviews OK | Details + Reviews OK |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|---|---|:---:|
| SPIFFE identity per SA | Cryptographic workload identity issued by istiod | Yes — mTLS / identity |
| AuthorizationPolicy (DENY) | Blocks traffic by source namespace | Yes — mesh security |
| AuthorizationPolicy (ALLOW) | Allows traffic by SPIFFE principal | Yes — mesh security |
| Waypoint proxy | Enforces L7 AuthorizationPolicy via `targetRefs` | Yes — L7 data plane |
| ztunnel | Carries SPIFFE identity in HBONE mTLS tunnels | Yes — L4 data plane |
| `SERVICES_DOMAIN` env var | App resolves services in another namespace via DNS | Kubernetes (DNS) |

## Key Takeaway

The mesh identifies every workload by its SPIFFE identity (`spiffe://cluster.local/ns/<namespace>/sa/<service-account>`), regardless of namespace or network location. AuthorizationPolicies enforce access control based on these cryptographic identities without any application code changes or pod restarts. This enables a Zero Trust model where cross-namespace access must be explicitly authorized.
