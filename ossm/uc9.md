# UC9: Special Case of Custom Certificate — Ambient (OSSM 3.2)

## Objective

Demostrar el caso donde un destino externo usa un **certificado no público** (self-signed o CA privada) y se requiere un manejo **por-destino** para confiar en esa CA **sin** relajar la verificación TLS para el resto del mesh.

En este demo:

- La ruta “default/strict” **no** confía en la CA privada → falla el handshake TLS.
- La ruta “custom-ca” usa una CA dedicada **solo** para ese destino → funciona.

## Quick Run

```bash
./ossm/uc9-verify.sh east
```

Para WEST:

```bash
./ossm/uc9-verify.sh west
```

Variables útiles:

- `AUTO_ENABLE_DNS_CAPTURE=true`: auto-habilita DNS capture si está apagado
- `KEEP_RESOURCES_ON_FAIL=true`: deja recursos para inspección
- `NO_PAUSE=true`: modo no interactivo
- `CUSTOM_CA_HEADER=x-bank-custom-ca`: header que activa la ruta con CA custom (por defecto `x-bank-custom-ca: true`)
- `BUILD_MODE=binary|git|prebuilt`: controla cómo se obtiene la imagen (por defecto: `binary`)
  - `binary`: usa `start-build --from-dir` (hace upload; permite probar sin pushear cambios)
  - `git`: el build se hace en-cluster clonando el repo (evita el “upload” del directorio local; requiere que el repo remoto tenga `ossm/uc9/...`)
  - `prebuilt`: no construye; usa `CUSTOM_CERT_SERVER_IMAGE` y `HAPROXY_IMAGE`
- `GIT_REPO_URL=https://...`: fuerza la URL del repo para `BUILD_MODE=git`
- `IMAGE_BUILD_NS=uc-images`: namespace **no ambient** donde corren los Builds (evita que aparezcan en Kiali)
- `KIALI_DEMO=true`: despliega un generador de tráfico en background y **no** limpia recursos (para mostrar en Kiali)
- `TRAFFIC_PERIOD_SEC=2`: intervalo entre requests del generador

## Expected Results

| Request | Header `x-bank-custom-ca` | Result |
|---|---:|---|
| `GET http://customcert.bank.demo/` | *(none)* | **FAIL** |
| `GET http://customcert.bank.demo/` | `true` | **200 OK** |

## Demo en Kiali (pasos)

1) Ejecuta UC9 en modo demo:

```bash
NO_PAUSE=true KIALI_DEMO=true ./ossm/uc9-verify.sh east
```

2) Abre Kiali y mira el **Graph** (Workload graph) para estos namespaces:

- `bookinfo` (cliente/generador; o el que uses como `TRAFFIC_NS`)
- `egress-custom-cert` (waypoint + connectors)
- `custom-cert-backend` (backend TLS con CA privada)

3) Espera 1–2 minutos y selecciona rango “Last 1m/5m”. Deberías ver:

- tráfico alternando hacia **strict connector** (errores de verificación) y **custom-ca connector** (OK)

