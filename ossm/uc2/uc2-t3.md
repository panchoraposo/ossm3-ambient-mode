# UC2-T3: Unified Trust & mTLS Verification

## Objective

Verify that both clusters share a single Root CA (unified trust), that mTLS is enabled by default for all traffic without manual certificate injection, and that all inter-service traffic is encrypted in transit via ztunnel's HBONE tunneling.

## Prerequisites

- Both clusters running with bookinfo deployed
- `generate-traffic.sh` running for Kiali visualization
- Kiali open (OSSMC via ACM console):
  https://console-openshift-console.apps.cluster-72nh2.dynamic.redhatworkshops.io/ossmconsole/graph

## Quick Run

```bash
./ossm/uc2-t3-verify.sh
```

## Manual Steps

### 1. Verify shared Root CA

Both clusters use intermediate CAs signed by the same Root CA.

```bash
# Root CA fingerprint — must be identical
oc --context east get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout -sha256
oc --context west get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -fingerprint -noout -sha256
```

Expected: **identical SHA-256 fingerprint** on both clusters.

### 2. Verify CA hierarchy

```bash
# Root CA
oc --context east get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -text -noout | grep -E "Issuer:|Subject:"

# Intermediate CA per cluster
oc --context east get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | openssl x509 -text -noout | grep -E "Issuer:|Subject:"
oc --context west get secret cacerts -n istio-system -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | openssl x509 -text -noout | grep -E "Issuer:|Subject:"
```

Expected hierarchy:
- Root CA: `O=Istio, CN=Root CA` (shared)
- Intermediate EAST: `O=Istio, CN=Intermediate CA east` (signed by Root CA)
- Intermediate WEST: `O=Istio, CN=Intermediate CA west` (signed by Root CA)

### 3. Verify mTLS is automatic (no PeerAuthentication needed)

```bash
oc --context east get peerauthentication -A
oc --context west get peerauthentication -A
```

Expected: `No resources found`. In ambient mode, mTLS is **always on** — ztunnel enforces it by default without any `PeerAuthentication` resource.

***Note***: if you see any `PeerAuthentication` resources, it might have been created by ConnectivityLink/Kuadrant.

### 4. Verify SPIFFE identities in traffic

```bash
oc --context east logs -n ztunnel ds/ztunnel --tail=10 | grep -o 'src.identity="[^"]*"\|dst.identity="[^"]*"' | sort -u
```

Expected: SPIFFE identities like:
```
src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
dst.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-reviews"
```

All identities share the `cluster.local` trust domain.

### 5. Verify HBONE encryption (port 15008)

```bash
oc --context east logs -n ztunnel ds/ztunnel --tail=10 | grep -o 'dst.addr=[^ ]*' | head -5
```

Expected: all destinations use **port 15008** (HBONE = HTTP-Based Overlay Network Environment over mTLS). Application traffic on port 9080 is tunneled through mTLS on 15008:

```
dst.addr=10.x.x.x:15008 dst.hbone_addr=10.x.x.x:9080
```

This means: original traffic to port 9080 is **always** encrypted via HBONE tunnel on port 15008.

## Expected Results

| Component | EAST | WEST |
|-----------|------|------|
| Root CA | `O=Istio, CN=Root CA` | `O=Istio, CN=Root CA` |
| Root CA fingerprint | **Identical** | **Identical** |
| Intermediate CA | `CN=Intermediate CA east` | `CN=Intermediate CA west` |
| PeerAuthentication | None needed | None needed |
| mTLS | Always on (ztunnel) | Always on (ztunnel) |
| SPIFFE trust domain | `cluster.local` | `cluster.local` |
| Traffic encryption | HBONE port 15008 | HBONE port 15008 |

## What is Service Mesh here

| Component | Role | Mesh feature? |
|-----------|------|:------------:|
| Shared Root CA | Unified trust domain across clusters | Yes — mTLS PKI |
| Per-cluster Intermediate CAs | Issue workload certificates locally | Yes — mTLS PKI |
| SPIFFE identities | Cryptographic identity per ServiceAccount | Yes — identity |
| ztunnel | Enforces mTLS on every connection, HBONE tunneling | Yes — L4 data plane |
| HBONE (port 15008) | Encrypted tunnel for all pod-to-pod traffic | Yes — mesh transport |
| istiod | Distributes certificates to ztunnel | Yes — control plane |

## Key Takeaway

In ambient mode, mTLS is **not optional** — it's built into the infrastructure. Every connection between pods goes through ztunnel, which automatically establishes HBONE tunnels over mTLS. No `PeerAuthentication` resources, no certificate injection into pods, no sidecar configuration. The shared Root CA with per-cluster intermediate CAs enables cross-cluster trust without sharing private keys.
