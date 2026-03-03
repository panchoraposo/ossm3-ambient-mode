# UC2-T4: mTLS Enforcement with PeerAuthentication STRICT

## Objective

Apply a `PeerAuthentication` policy in STRICT mode to the root namespace and demonstrate that non-mTLS (plaintext) traffic from outside the mesh is rejected, while mesh-internal mTLS traffic continues working.

## Prerequisites

- Both clusters running with bookinfo deployed
- `generate-traffic.sh` running (optional)
- Kiali open (OSSMC via ACM console)

## Quick Run

```bash
./ossm/uc2-t4-verify.sh
```

## Manual Steps

### 1. Verify baseline — plaintext access works (PERMISSIVE)

Create a namespace **outside the mesh** (no `istio.io/dataplane-mode=ambient` label):

```bash
oc --context east create namespace outside-mesh
```

Deploy a test pod:

```bash
oc --context east run curl-test --image=curlimages/curl --namespace=outside-mesh --restart=Never --command -- sleep 3600
```

Wait for the pod to be Running, then test access to a mesh service:

```bash
oc --context east exec curl-test -n outside-mesh -- curl -s -o /dev/null -w "HTTP %{http_code}\n" -m 5 http://productpage.bookinfo.svc.cluster.local:9080/productpage
```

Expected: **HTTP 200** — plaintext access works because the default mode is PERMISSIVE.

Also verify mesh-internal traffic works:

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Expected: **HTTP 200**.

### 2. Apply PeerAuthentication STRICT

```bash
oc --context east apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
```

This applies STRICT mTLS to the entire mesh managed by this istiod. Only mTLS connections are accepted.

### 3. Verify — plaintext REJECTED, mTLS WORKS

From the non-mesh pod (plaintext):

```bash
oc --context east exec curl-test -n outside-mesh -- curl -s -o /dev/null -w "HTTP %{http_code}\n" -m 5 http://productpage.bookinfo.svc.cluster.local:9080/productpage
```

Expected: **HTTP 000** (connection reset) — plaintext traffic is rejected.

From mesh-internal traffic (mTLS via ztunnel):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Expected: **HTTP 200** — mTLS traffic continues working.

### 4. Cleanup

```bash
oc --context east delete peerauthentication strict-mtls -n istio-system
oc --context east delete pod curl-test -n outside-mesh
oc --context east delete namespace outside-mesh
```

### 5. Verify recovery

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://bookinfo.apps.cluster-64k4b.64k4b.sandbox5146.opentlc.com/productpage
```

Expected: HTTP 200.

## Expected Results

| Phase | Non-mesh pod (plaintext) | Mesh traffic (mTLS) |
|-------|--------------------------|---------------------|
| Default (PERMISSIVE) | **HTTP 200** (accepted) | HTTP 200 |
| STRICT applied | **HTTP 000** (rejected) | HTTP 200 |
| After cleanup | N/A (pod deleted) | HTTP 200 |

## Key Takeaway

In ambient mode, mTLS between mesh services is always on by default. `PeerAuthentication` STRICT adds an extra layer: it rejects plaintext connections from pods **outside** the mesh. This is the zero-trust enforcement — no service can communicate with the mesh unless it speaks mTLS. The change is immediate, requires no pod restarts, and is applied mesh-wide from the root namespace.
