# UC2-T2: ServiceAccount-Based Enablement (Cross-Namespace Identity)

> **Alcance**: El caso de uso original plantea contexto multi-cluster (EAST→WEST). En OSSM 3.2 (Istio 1.27) ambient mode, el data plane cross-cluster no soporta waypoints, por lo que aquí se demuestra la misma funcionalidad single-cluster. La mecánica SPIFFE es idéntica cross-namespace y cross-cluster, ya que la identidad es `spiffe://cluster.local/ns/<ns>/sa/<sa>` independientemente del cluster de origen.

## Objective

Demonstrate that the mesh enforces access control based on SPIFFE identities (ServiceAccount-based). A service in a different namespace can only access `reviews` in `bookinfo` if its ServiceAccount is explicitly authorized.

## Architecture
- `bookinfo-external` is enrolled in the mesh (ambient mode)
- productpage in `bookinfo-external` uses `SERVICES_DOMAIN=bookinfo.svc.cluster.local` to call services in `bookinfo`
- The mesh identifies each caller by its SPIFFE identity: `spiffe://cluster.local/ns/<namespace>/sa/<service-account>`

## Prerequisites

- Both clusters running with bookinfo deployed
- Namespace `bookinfo-external` deployed and enrolled in ambient mode
- `generate-traffic.sh` running for Kiali visualization
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Quick Run

```bash
./ossm/uc2-t2-verify.sh
```

## Test Flow

### Phase 1: Verify `bookinfo-external` is available

The `bookinfo-external` namespace is deployed by the Ansible playbook. It contains a copy of `productpage` with `SERVICES_DOMAIN=bookinfo.svc.cluster.local`, which calls `reviews`, `details`, and `ratings` in the `bookinfo` namespace. It uses a different ServiceAccount (`bookinfo-external-productpage`), giving it a distinct SPIFFE identity.

```bash
oc --context east get namespace bookinfo-external --show-labels
oc --context east get pods -n bookinfo-external
oc --context east get route -n bookinfo-external
```

Verify:
- Namespace has `istio.io/dataplane-mode=ambient`
- productpage pod is `Running`
- Route exposes `bookinfo-external.apps.<cluster-domain>`

### Phase 2: Verify both Routes work (no policy)

```bash
curl -s -o /dev/null -w "%{http_code}" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
curl -s -o /dev/null -w "%{http_code}" http://bookinfo-external.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Expected: both return HTTP 200 with Book Details and Book Reviews.

### Phase 3: Apply AuthorizationPolicy (DENY external)

```bash
oc --context east apply -f - <<EOF
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

> **Note:** In ambient mode, `targetRefs` (pointing to a Service) must be used instead of `selector.matchLabels`. The waypoint proxy enforces the policy on behalf of the target service.

Expected:
- **Original bookinfo**: HTTP 200 — Book Details + Book Reviews (works)
- **External**: HTTP 200 — Book Details OK, **Error fetching product reviews** (denied)

### Phase 4: Switch to ALLOW with both identities

```bash
oc --context east delete authorizationpolicy reviews-deny-external -n bookinfo
oc --context east apply -f - <<EOF
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

Expected: both Routes return HTTP 200 with Book Details + Book Reviews.

### Phase 5: Cleanup

```bash
oc --context east delete authorizationpolicy reviews-allow-by-identity -n bookinfo
```

## Expected Results

| Phase | Original bookinfo | External bookinfo |
|-------|-------------------|-------------------|
| No policy | Details + Reviews OK | Details + Reviews OK |
| DENY external namespace | Details + Reviews OK | Details OK, **Reviews DENIED** |
| ALLOW both SAs | Details + Reviews OK | Details + Reviews OK |
| After cleanup | Details + Reviews OK | Details + Reviews OK |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| SPIFFE identity per SA | Cryptographic workload identity | Yes — mTLS / identity |
| AuthorizationPolicy (DENY) | Blocks traffic by source namespace | Yes — mesh security |
| AuthorizationPolicy (ALLOW) | Allows traffic by SPIFFE principal | Yes — mesh security |
| ztunnel | Enforces policy at L4 per identity | Yes — L4 data plane |
| istiod | Issues certificates, pushes policies | Yes — control plane |
| Cross-namespace `SERVICES_DOMAIN` | App resolves services in another namespace | Kubernetes (DNS) |

## Key Takeaway

The mesh identifies every workload by its SPIFFE identity (`spiffe://cluster.local/ns/<namespace>/sa/<service-account>`), regardless of namespace or network location. AuthorizationPolicies enforce access control based on these cryptographic identities without requiring any changes to application code or pod restarts. This enables a Zero Trust model where cross-namespace access must be explicitly authorized.
