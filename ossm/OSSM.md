# OpenShift Service Mesh 3.2 — Ambient Mode

## De Sidecars a Ambient Mode

### El modelo sidecar (OSSM 2.x / Istio clásico)

En OSSM 2.x, cada pod de la aplicación tenía un **contenedor Envoy inyectado** (sidecar). Todo el tráfico entrante y saliente del pod pasaba por ese Envoy:

```
[Pod: productpage]
  ├── container: productpage (la app)
  └── container: istio-proxy (Envoy sidecar) ← intercepta todo el tráfico
```

El sidecar hacía TODO: mTLS, L4, L7, métricas, tracing, policies. Funcionaba, pero tenía costes:

- **Recursos**: cada pod consumía CPU/RAM extra por el sidecar
- **Latencia**: cada hop pasaba por dos Envoys (source + destination)
- **Operaciones**: actualizar Istio requería reiniciar todos los pods para actualizar los sidecars

### El modelo ambient (OSSM 3.2)

Ambient mode **elimina los sidecars**. En su lugar divide las responsabilidades en dos capas:

```
┌─────────────────────────────────────────────────┐
│  CAPA L7 (opcional)     →  Waypoint Proxies     │
│  (HTTP routing, retries, AuthZ L7, métricas)    │
├─────────────────────────────────────────────────┤
│  CAPA L4 (siempre)      →  ztunnel              │
│  (mTLS, identidad SPIFFE, TCP metrics)          │
└─────────────────────────────────────────────────┘
```

Los pods son **limpios**, sin sidecar — muestran `1/1 READY` en vez del `2/2` que se veía con sidecars.

---

## Componentes

### 1. ztunnel (capa L4 — siempre activa)

Es un **DaemonSet** que corre un pod por nodo (namespace `ztunnel`). Es un proxy ligero escrito en Rust (no es Envoy) que:

- **Intercepta todo el tráfico** de los pods en namespaces ambient (vía reglas del CNI)
- Establece **mTLS automático** entre pods (identidad SPIFFE, certificados X.509)
- Crea **túneles HBONE** para transportar el tráfico (ver sección siguiente)
- Proporciona métricas L4 (bytes, conexiones TCP)

Cuando un pod envía tráfico a otro pod:

```
productpage → [ztunnel nodo origen] ==HBONE/mTLS==> [ztunnel nodo destino] → reviews
```

El pod nunca se entera de que su tráfico está siendo interceptado.

#### mTLS en ambient mode

**mTLS está activo automáticamente.** No se necesita configurar `PeerAuthentication` ni `DestinationRule` como en sidecar mode. En el momento en que el namespace tiene `istio.io/dataplane-mode: ambient`, el ztunnel cifra todo el tráfico entre pods con mTLS usando certificados SPIFFE emitidos por istiod.

Cada workload recibe una identidad SPIFFE automáticamente, verificable en los logs del ztunnel:

```
src.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-gateway-istio"
dst.identity="spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage"
```

#### ¿Qué es HBONE?

HBONE = **HTTP-Based Overlay Network Environment**. Es el protocolo de transporte que usa Istio para ambient mode.

En sidecar mode, los Envoys se hablaban entre sí con mTLS directo (TCP puro cifrado con TLS). En ambient, el ztunnel usa algo más sofisticado: un túnel **HTTP/2 CONNECT** encapsulado dentro de una conexión **mTLS** en el puerto **15008**:

```
Pod A → ztunnel A → [HTTP/2 CONNECT sobre mTLS, puerto 15008] → ztunnel B → Pod B
```

Capa por capa:

- La capa exterior es **TLS** (autenticación mutua con certs SPIFFE)
- Dentro va un **HTTP/2 CONNECT** que dice "quiero conectar con el pod X en el puerto Y"
- Dentro del CONNECT va el **tráfico original** de la aplicación (sin modificar)

¿Por qué no usar mTLS directo como antes? Porque HBONE permite:

- **Multiplexar** varias conexiones de distintos pods sobre un mismo túnel
- Llevar **metadatos** (identidad, destino original) dentro del protocolo HTTP
- Funcionar mejor atravesando **load balancers y proxies intermedios** (como el east-west gateway entre clústeres)

### 2. Waypoint Proxies (capa L7 — opcional por servicio)

En el modelo sidecar, **todo** pod tenía L7. En ambient, L7 es **opcional** y se activa por servicio mediante los **waypoints**.

Un waypoint es un **Deployment de Envoy** dedicado a un servicio, desplegado como un `Gateway` de Kubernetes con clase `istio-waypoint`.

#### GatewayClass: `istio` vs `istio-waypoint`

En la Gateway API de Kubernetes, cada `Gateway` necesita un **GatewayClass** que diga "quién lo implementa". Istio registra dos clases en el clúster:

| GatewayClass | Para qué sirve |
|---|---|
| `istio` | Gateways de **ingress/egress** (recibe tráfico externo, como `bookinfo-gateway`) |
| `istio-waypoint` | Waypoint proxies **internos** de la mesh (procesan tráfico L7 entre servicios) |

Cuando se crea un Gateway con `gatewayClassName: istio-waypoint`, Istio no crea un ingress, sino que crea un **Deployment de Envoy interno** que actúa como proxy L7 para un servicio de la mesh.

```yaml
kind: Gateway
metadata:
  name: productpage-waypoint
  labels:
    istio.io/waypoint-for: all    # Aplica a Services y Workloads
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE             # Recibe tráfico via túnel HBONE
```

#### `istio.io/waypoint-for`: alcance del waypoint

El label `istio.io/waypoint-for` controla qué tipo de tráfico procesa el waypoint:

| Valor | Qué tráfico procesa |
|---|---|
| `service` | Solo tráfico dirigido al **Service**. **Valor por defecto.** |
| `workload` | Solo tráfico dirigido directamente al **Pod IP** (bypassing el Service) |
| `all` | Ambos: tráfico al Service **y** tráfico directo al Pod IP |

En este despliegue se usa `all` porque el ingress gateway conecta directamente al Pod IP vía HBONE (no por el Service ClusterIP), así que el waypoint necesita interceptar también ese tráfico directo al workload.

#### Conectar un Service de Kubernetes a su waypoint

Se usa el label `istio.io/use-waypoint` en el **Service de Kubernetes**:

```yaml
kind: Service
metadata:
  name: productpage
  labels:
    istio.io/use-waypoint: productpage-waypoint
```

Sin este label, el tráfico solo pasa por ztunnel (L4). Con el label, el ztunnel desvía el tráfico al waypoint para procesamiento L7 antes de entregarlo al destino.

El label se puede poner a distintos niveles:

| Alcance | Dónde poner `istio.io/use-waypoint` | Ejemplo |
|---|---|---|
| **Per-service** (este despliegue) | En cada `Service` de K8s | Cada servicio de bookinfo tiene su propio waypoint |
| **Per-namespace** | En el `Namespace` | Todos los servicios del namespace comparten un waypoint |
| **Per-workload** | En el pod template del `Deployment` | Para interceptar tráfico directo al pod (como productpage-v1) |

Varios Services pueden compartir un mismo waypoint, o cada uno puede tener el suyo (como en este despliegue: 4 Services, 4 waypoints).

### 3. Ingress Gateway

Se usa la **Gateway API** de Kubernetes (no los antiguos Istio Gateway/VirtualService):

```yaml
kind: Gateway
metadata:
  name: bookinfo-gateway
spec:
  gatewayClassName: istio           # Clase "istio" (no "istio-waypoint")
  listeners:
    - name: http
      port: 80
      protocol: HTTP
```

El gateway pod tiene `istio.io/dataplane-mode: none` (no es interceptado por ztunnel) y su propio Envoy que habla HBONE directamente con los waypoints/ztunnel.

### 4. Namespace enrollment

```yaml
kind: Namespace
metadata:
  name: bookinfo
  labels:
    istio.io/dataplane-mode: ambient      # Enrolla TODOS los pods en ambient
    istio-discovery: enabled               # Istiod descubre este namespace
    openshift.io/user-monitoring: "true"   # Prometheus scraping habilitado
```

Con `dataplane-mode: ambient`, todos los pods del namespace son automáticamente interceptados por el ztunnel. No se necesitan labels de inyección en los pods individuales.

---

## Flujo completo (bookinfo)

Cuando un usuario accede a `http://bookinfo.apps.<cluster>/productpage`:

```
Browser
  │
  ▼
OpenShift Router (HAProxy)           ← Entrada al clúster
  │
  ▼
bookinfo-gateway-istio (Envoy)       ← Gateway API, clase "istio"
  │                                     Tiene su propio Envoy pero NO es
  │                                     interceptado por ztunnel
  │                                     (label: dataplane-mode: none)
  │  HBONE/mTLS
  ▼
productpage-waypoint (Envoy)         ← Waypoint L7
  │
  │  HBONE/mTLS via ztunnel
  ▼
ztunnel → productpage pod :9080      ← La app (sin sidecar, 1 contenedor)
  │
  │  productpage llama a reviews:9080 y details:9080
  ▼
ztunnel (intercepta salida)
  │  HBONE/mTLS
  ▼
reviews-waypoint (Envoy L7)          ← Waypoint de reviews
  │
  ▼
ztunnel → reviews-v1/v2/v3 :9080    ← Una de las versiones
  │
  │  reviews llama a ratings:9080
  ▼
ztunnel → ratings-waypoint → ztunnel → ratings-v1 :9080
```

---

## Comparación sidecar vs ambient

| Concepto | Sidecar mode | Ambient mode |
|---|---|---|
| **mTLS** | Sidecar Envoy en cada pod | ztunnel (DaemonSet, 1 por nodo) |
| **Identidad** | Cert en el sidecar | Cert en el ztunnel (SPIFFE) |
| **L7 (HTTP)** | Sidecar Envoy en cada pod | Waypoint proxy (1 por servicio) |
| **Inyección** | Label `istio-injection=enabled` en NS | Label `istio.io/dataplane-mode: ambient` en NS |
| **Pods** | `2/2` (app + sidecar) | `1/1` (solo app) |
| **Protocolo entre nodos** | mTLS directo (TCP) | HBONE (HTTP CONNECT sobre mTLS, puerto 15008) |
| **Gateway ingress** | Sidecar injection en gateway pod | Gateway API con `dataplane-mode: none` |
| **Activar L7 por servicio** | No posible (todo o nada) | `istio.io/use-waypoint` en el Service |

---

## Ventajas clave de ambient

1. **L7 granular**: Solo los servicios que lo necesitan tienen waypoint. Si un servicio solo necesita mTLS, ztunnel se lo da sin waypoint.

2. **Multi-cluster con HBONE**: El protocolo HBONE es el mismo entre pods locales y entre clústeres (east ↔ west) a través del east-west gateway. Los servicios con `istio.io/global: "true"` pueden descubrirse y comunicarse entre clústeres de forma transparente.

3. **Recursos reducidos**: En vez de N sidecars Envoy (uno por pod), hay 1 ztunnel compartido por nodo + waypoints por Service de K8s que lo necesite.

4. **Sin reinicio de pods para updates**: Actualizar Istio no requiere reiniciar los pods de la aplicación (el ztunnel se actualiza como DaemonSet).

---

## Nota operativa: reinicio de nodos

Tras un reinicio de nodo, los pods se recrean pero las reglas de redirección del CNI de Istio ambient pueden no restablecerse correctamente. Si el tráfico HBONE falla con timeouts (`connection failed: deadline has elapsed` en los logs de ztunnel), es necesario hacer `rollout restart` de los deployments para que el CNI reconfigure las reglas de red en los nuevos pods.
