# OpenShift Service Mesh 3.2 — Ambient Mode Reference Guide

This document provides a comprehensive reference for **Red Hat OpenShift Service Mesh (OSSM) 3.2** in **ambient mode**. It covers the architecture, key components, traffic flow, and operational considerations based on hands-on experience with the bookinfo application across a multi-cluster (Multi-Primary) OpenShift 4.20 environment.

---

## From Sidecars to Ambient Mode

### The sidecar model (OSSM 2.x / classic Istio)

In OSSM 2.x, every application pod had an **Envoy sidecar container injected**. All inbound and outbound traffic passed through that Envoy:

```
[Pod: productpage]
  ├── container: productpage (the application)
  └── container: istio-proxy (Envoy sidecar) ← intercepts all traffic
```

The sidecar handled everything: mTLS, L4, L7, metrics, tracing, policies. It worked, but had costs:

- **Resources**: each pod consumed extra CPU/RAM for the sidecar
- **Latency**: each hop passed through two Envoys (source + destination)
- **Operations**: upgrading Istio required restarting all pods to update their sidecars
- **Blast radius**: a misconfigured sidecar could break the application pod

### The ambient model (OSSM 3.2)

Ambient mode **eliminates sidecars**. Instead, it splits responsibilities into two layers:

```
┌─────────────────────────────────────────────────┐
│  L7 LAYER (optional)    →  Waypoint Proxies     │
│  (HTTP routing, retries, AuthZ L7, metrics)     │
├─────────────────────────────────────────────────┤
│  L4 LAYER (always on)   →  ztunnel              │
│  (mTLS, SPIFFE identity, TCP metrics)           │
└─────────────────────────────────────────────────┘
```

Application pods are **clean** — no sidecar injected. They show `1/1 READY` instead of the `2/2` seen with sidecars.

---

## Core Components

### 1. ztunnel (L4 — always active)

A **DaemonSet** running one pod per node (namespace `ztunnel`). It is a lightweight proxy written in **Rust** (not Envoy) that:

- **Intercepts all traffic** from pods in ambient-enrolled namespaces (via CNI rules)
- Establishes **automatic mTLS** between pods using SPIFFE X.509 certificates
- Creates **HBONE tunnels** for encrypted transport (see below)
- Provides L4 metrics (bytes, TCP connections)

When a pod sends traffic to another pod:

```
productpage → [ztunnel on source node] ==HBONE/mTLS==> [ztunnel on dest node] → reviews
```

The application pod is completely unaware that its traffic is being intercepted and encrypted.

#### mTLS in ambient mode

**mTLS is always on by default.** There is no need to configure `PeerAuthentication` or `DestinationRule` as in sidecar mode. As soon as a namespace has `istio.io/dataplane-mode: ambient`, ztunnel encrypts all inter-pod traffic with mTLS using SPIFFE certificates issued by istiod.

Each workload receives a SPIFFE identity automatically, visible in ztunnel logs:

```
src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
dst.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-reviews"
```

> **Demonstrated in**: UC2-T3 (Unified Trust & mTLS Verification), UC2-T4 (mTLS Enforcement with PeerAuthentication STRICT)

#### What is HBONE?

HBONE = **HTTP-Based Overlay Network Environment**. It is the transport protocol used by Istio in ambient mode.

In sidecar mode, Envoys communicated via direct mTLS (raw TCP encrypted with TLS). In ambient mode, ztunnel uses something more sophisticated: an **HTTP/2 CONNECT** tunnel encapsulated inside an **mTLS** connection on port **15008**:

```
Pod A → ztunnel A → [HTTP/2 CONNECT over mTLS, port 15008] → ztunnel B → Pod B
```

Layer by layer:

- The outer layer is **TLS** (mutual authentication with SPIFFE certificates)
- Inside is an **HTTP/2 CONNECT** that says "I want to connect to pod X on port Y"
- Inside the CONNECT is the **original application traffic** (unmodified)

Why not use direct mTLS like before? Because HBONE enables:

- **Multiplexing** multiple connections from different pods over a single tunnel
- Carrying **metadata** (identity, original destination) inside the HTTP protocol
- Better traversal of **intermediate load balancers and proxies** (such as east-west gateways between clusters)

> **Demonstrated in**: UC2-T3 (HBONE on port 15008 verified in ztunnel logs), UC13 (local-first traffic verified through ztunnel log analysis)

### 2. Waypoint Proxies (L7 — optional, per service)

In the sidecar model, **every** pod had L7 capability. In ambient mode, L7 is **optional** and activated per service through **waypoint proxies**.

A waypoint is an **Envoy Deployment** dedicated to a service, deployed as a Kubernetes `Gateway` with class `istio-waypoint`.

#### GatewayClass: `istio` vs `istio-waypoint`

In the Kubernetes Gateway API, each `Gateway` needs a **GatewayClass** defining its implementation. Istio registers two classes:

| GatewayClass | Purpose |
|---|---|
| `istio` | **Ingress/egress** gateways (receives external traffic, e.g. `bookinfo-gateway`) |
| `istio-waypoint` | **Internal** mesh waypoint proxies (processes L7 traffic between services) |

When a Gateway is created with `gatewayClassName: istio-waypoint`, Istio creates an **internal Envoy Deployment** that acts as an L7 proxy for mesh services.

```yaml
kind: Gateway
metadata:
  name: reviews-waypoint
  labels:
    istio.io/waypoint-for: all
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

#### `istio.io/waypoint-for`: waypoint scope

The label `istio.io/waypoint-for` controls what type of traffic the waypoint processes:

| Value | Traffic processed |
|---|---|
| `service` | Only traffic addressed to the **Service** (ClusterIP). **Default.** |
| `workload` | Only traffic addressed directly to the **Pod IP** |
| `all` | Both: Service traffic **and** direct Pod IP traffic |

In this deployment, `all` is used because the ingress gateway connects directly to the Pod IP via HBONE (not via the Service ClusterIP), so the waypoint needs to intercept both types of traffic.

#### Connecting a Kubernetes Service to its waypoint

Use the label `istio.io/use-waypoint` on the **Kubernetes Service**:

```yaml
kind: Service
metadata:
  name: reviews
  labels:
    istio.io/use-waypoint: reviews-waypoint
```

Without this label, traffic only passes through ztunnel (L4). With the label, ztunnel redirects traffic to the waypoint for L7 processing before delivering it to the destination.

The label can be applied at different scopes:

| Scope | Where to put `istio.io/use-waypoint` | Effect |
|---|---|---|
| **Per-service** (this deployment) | On each Kubernetes `Service` | Each bookinfo service has its own waypoint |
| **Per-namespace** | On the `Namespace` | All services in the namespace share one waypoint |
| **Per-workload** | On the pod template of the `Deployment` | Intercepts traffic addressed directly to the pod |

> **Demonstrated in**: UC1-T6 (L4 vs L7 segregation), UC12 (Blue/Green via HTTPRoute + waypoint)

### 3. Ingress Gateway

Uses the **Kubernetes Gateway API** (not the legacy Istio Gateway/VirtualService):

```yaml
kind: Gateway
metadata:
  name: bookinfo-gateway
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      port: 80
      protocol: HTTP
```

The gateway pod has `istio.io/dataplane-mode: none` (it is not intercepted by ztunnel) because it runs its own Envoy that speaks HBONE directly with waypoints and ztunnel.

An **OpenShift Route** exposes the gateway service externally:

```yaml
kind: Route
metadata:
  name: bookinfo
spec:
  host: bookinfo.apps.<cluster-domain>
  to:
    kind: Service
    name: bookinfo-gateway-istio
```

> **Demonstrated in**: UC12 (Blue/Green via HTTPRoute on the ingress gateway)

### 4. Namespace Enrollment

```yaml
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio.io/dataplane-mode: ambient
    istio-discovery: enabled
    openshift.io/user-monitoring: "true"
```

With `dataplane-mode: ambient`, all pods in the namespace are automatically intercepted by ztunnel. No per-pod injection labels needed.

> **Demonstrated in**: UC1-T2 (no sidecars verification), UC2-T2 (bookinfo-external enrolled separately)

---

## Traffic Flow (bookinfo)

When a user accesses `http://bookinfo.apps.<cluster>/productpage`:

```
Browser
  │
  ▼
OpenShift Router (HAProxy)           ← Cluster ingress
  │
  ▼
bookinfo-gateway-istio (Envoy)       ← Gateway API, class "istio"
  │                                     Has its own Envoy, NOT intercepted
  │                                     by ztunnel (dataplane-mode: none)
  │  HBONE/mTLS
  ▼
productpage-waypoint (Envoy)         ← L7 Waypoint
  │
  │  HBONE/mTLS via ztunnel
  ▼
ztunnel → productpage pod :9080      ← App (no sidecar, 1 container)
  │
  │  productpage calls reviews:9080 and details:9080
  ▼
ztunnel (intercepts outbound)
  │  HBONE/mTLS
  ▼
reviews-waypoint (Envoy L7)          ← Reviews waypoint
  │
  ▼
ztunnel → reviews-v1/v2/v3 :9080    ← One of the versions
  │
  │  reviews calls ratings:9080
  ▼
ztunnel → ratings-waypoint → ztunnel → ratings-v1 :9080
```

---

## Sidecar vs Ambient Comparison

| Concept | Sidecar mode | Ambient mode |
|---|---|---|
| **mTLS** | Sidecar Envoy in each pod | ztunnel (DaemonSet, 1 per node) |
| **Identity** | Certificate in the sidecar | Certificate in ztunnel (SPIFFE) |
| **L7 (HTTP)** | Sidecar Envoy in each pod | Waypoint proxy (optional, per service) |
| **Enrollment** | `istio-injection=enabled` on NS | `istio.io/dataplane-mode: ambient` on NS |
| **Pod containers** | `2/2` (app + sidecar) | `1/1` (app only) |
| **Inter-node protocol** | Direct mTLS (TCP) | HBONE (HTTP/2 CONNECT over mTLS, port 15008) |
| **Ingress gateway** | Sidecar injection in gateway pod | Gateway API with `dataplane-mode: none` |
| **L7 per service** | Not possible (all or nothing) | `istio.io/use-waypoint` on the Service |
| **Istio upgrade impact** | Restart all application pods | Update ztunnel DaemonSet; no app restarts |
| **Resource overhead** | N sidecars (1 per pod) | 1 ztunnel per node + waypoints as needed |

---

## Key Advantages of Ambient Mode

1. **Granular L7**: Only services that need it get a waypoint. Services that only need mTLS get it from ztunnel without any waypoint overhead.

2. **Infrastructure / Application separation**: Platform teams manage ztunnel (L4) independently from development teams managing waypoints (L7). Changes to either layer require no coordination and no pod restarts.
   > **Demonstrated in**: UC1-T6 (Infrastructure Segregation)

3. **Reduced resources**: Instead of N Envoy sidecars (one per pod), there is 1 shared ztunnel per node + waypoints only for services that need L7.

4. **No pod restarts for mesh updates**: Upgrading Istio does not require restarting application pods (ztunnel updates as a DaemonSet rolling update).

5. **Control Plane Independence**: In Multi-Primary topology, each cluster has its own istiod. If one fails, the other continues operating with cached configuration.
   > **Demonstrated in**: UC1-T5 (Control Plane Independence)

6. **Zero-Trust by default**: mTLS is always on. Combined with `AuthorizationPolicy` and `PeerAuthentication`, the mesh provides defense-in-depth without application changes.
   > **Demonstrated in**: UC2-T1 (Deny-All), UC2-T2 (Identity-Based Access), UC2-T4 (PeerAuthentication STRICT)

---

## Multi-Cluster Topology

This PoC uses a **Multi-Primary** topology:

- **Two OCP 4.20 clusters** (EAST and WEST), each with its own istiod
- **One ACM hub** for centralized management and Kiali (OSSMC)
- **Shared trust domain** (`cluster.local`) with a shared Root CA and per-cluster Intermediate CAs
- **Remote secrets** allow each istiod to discover the other cluster's endpoints

### What works

- **Control plane federation**: service discovery, remote secrets, shared trust
- **Independent control planes**: one istiod can fail without affecting the other cluster's data plane
- **Unified observability**: Kiali on ACM shows both clusters in a single graph

---

## Istio API Reference (OSSM 3.2)

| API Resource | Layer | Status in OSSM 3.2 | Used in |
|---|---|---|---|
| `AuthorizationPolicy` | L4/L7 security | GA (Stable) | UC1-T6, UC2-T1, UC2-T2 |
| `PeerAuthentication` | mTLS enforcement | GA (Stable) | UC2-T4 |
| `Telemetry` | Observability config | GA (Stable) | UC1-T6, UC13 |
| `Gateway` (K8s API) | Ingress / Waypoint | GA (Stable) | UC12 |
| `HTTPRoute` (K8s API) | L7 routing | GA (Stable) | UC12 |
| `VirtualService` | L7 routing (legacy) | TP (Alpha) | Not recommended for ambient |

> **Note**: `VirtualService` was tested but does not function correctly with waypoint proxies in ambient mode. Use `HTTPRoute` (Gateway API) instead for L7 traffic management.

---

## Operational Notes

### Post-restart recovery

After a node or cluster restart, pods are recreated but the Istio CNI ambient network redirection rules may not be re-established correctly. If HBONE traffic fails with timeouts (`connection failed: deadline has elapsed` in ztunnel logs), a `rollout restart` of the affected deployments forces the CNI to reconfigure network rules on the new pods.

The `morning-check.sh` script automates this recovery for the PoC sandbox environment.

### Traffic generation for Kiali

Two scripts are available:

| Script | Purpose | Use when |
|---|---|---|
| `generate-traffic.sh` | Simple continuous traffic to bookinfo (EAST, WEST) and bookinfo-external | During most use case demos — keeps Kiali graphs populated |
| `generate-traffic-realistic.sh` | Advanced mixed traffic with concurrency, jitter, bursts, and varied paths | Stress testing or realistic traffic pattern simulation |

For most use cases, run `generate-traffic.sh` in a separate terminal before starting the demo. **Exception**: UC12 (Blue/Green) has its own embedded traffic generation to target specific versioned endpoints.

---

## Use Case Index

| ID | Title | Scope |
|---|---|---|
| UC1-T1 | Baseline OpenShift Environments | Infrastructure |
| UC1-T2 | Deploying OSSM 3.2 in Ambient Mode | Mesh deployment |
| UC1-T3 | Multi-Primary Federation & Discovery | Control plane |
| UC1-T5 | Control Plane Independence | Resilience |
| UC1-T6 | Infrastructure Segregation (L4 vs Policy) | Architecture |
| UC2-T1 | The "Lockdown" (Deny-All Everywhere) | Security |
| UC2-T2 | ServiceAccount-Based Enablement | Identity / RBAC |
| UC2-T3 | Unified Trust & mTLS Verification | Trust / PKI |
| UC2-T4 | mTLS Enforcement (PeerAuthentication STRICT) | Security |
| UC12 | Blue/Green Deployment with Gateway API | Traffic management |
| UC13 | Local-First Traffic Awareness | Routing / observability |
