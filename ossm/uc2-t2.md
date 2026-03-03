# UC2-T2: ServiceAccount-Based Enablement (Cross-Namespace Identity)

## Objective

Demonstrate that the mesh enforces access control based on SPIFFE identities (ServiceAccount-based). A service in a different namespace can only access `reviews` in `bookinfo` if its ServiceAccount is explicitly authorized.

## Architecture
- `bookinfo-external` is enrolled in the mesh (ambient mode)
- productpage in `bookinfo-external` uses `SERVICES_DOMAIN=bookinfo.svc.cluster.local` to call services in `bookinfo`
- The mesh identifies each caller by its SPIFFE identity: `spiffe://cluster.local/ns/<namespace>/sa/<service-account>`

## Prerequisites

- Both clusters running with bookinfo deployed
- Namespace `bookinfo-external` created and enrolled in ambient mode (done by the verify script)
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Quick Run

```bash
./ossm/uc2-t2-verify.sh
```

## Test Flow

### Phase 1: Setup `bookinfo-external`

Create namespace with ambient mode, deploy productpage with `SERVICES_DOMAIN` pointing to `bookinfo`:

```bash
oc --context east create namespace bookinfo-external
oc --context east label namespace bookinfo-external istio.io/dataplane-mode=ambient
```

Deploy productpage:

```bash
oc --context east apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bookinfo-external-productpage
  namespace: bookinfo-external
---
apiVersion: v1
kind: Service
metadata:
  name: productpage
  namespace: bookinfo-external
  labels:
    app: productpage
spec:
  ports:
  - port: 9080
    name: http
  selector:
    app: productpage
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: productpage-v1
  namespace: bookinfo-external
spec:
  replicas: 1
  selector:
    matchLabels:
      app: productpage
      version: v1
  template:
    metadata:
      labels:
        app: productpage
        version: v1
    spec:
      serviceAccountName: bookinfo-external-productpage
      containers:
      - name: productpage
        image: quay.io/sail-dev/examples-bookinfo-productpage-v1:1.20.3
        ports:
        - containerPort: 9080
        env:
        - name: SERVICES_DOMAIN
          value: "bookinfo.svc.cluster.local"
        volumeMounts:
        - mountPath: /tmp
          name: tmp
      volumes:
      - emptyDir: {}
        name: tmp
EOF
```

Create Gateway + HTTPRoute + Route:

```bash
oc --context east apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: bookinfo-external-gateway
  namespace: bookinfo-external
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo-external
  namespace: bookinfo-external
spec:
  parentRefs:
  - name: bookinfo-external-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /productpage
    - path:
        type: PathPrefix
        value: /static
    - path:
        type: PathPrefix
        value: /login
    - path:
        type: PathPrefix
        value: /logout
    backendRefs:
    - name: productpage
      port: 9080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: bookinfo-external-gateway
  namespace: bookinfo-external
spec:
  host: bookinfo-external.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com
  port:
    targetPort: 80
  to:
    kind: Service
    name: bookinfo-external-gateway-istio
EOF
```

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
  selector:
    matchLabels:
      app: reviews
  action: DENY
  rules:
  - from:
    - source:
        namespaces:
        - bookinfo-external
EOF
```

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
  selector:
    matchLabels:
      app: reviews
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

## Key Takeaway

The mesh identifies every workload by its SPIFFE identity (`spiffe://cluster.local/ns/<namespace>/sa/<service-account>`), regardless of namespace or network location. AuthorizationPolicies enforce access control based on these cryptographic identities without requiring any changes to application code or pod restarts. This enables a Zero Trust model where cross-namespace access must be explicitly authorized.
