# UC9: Special Case of Custom Certificate — Ambient (OSSM 3.2)

## Objective

Demonstrate the case where an external/legacy destination uses a **non-public certificate** (self-signed or private CA) and we need **per-destination trust** without weakening TLS verification for the rest of the mesh.

In this demo:

- The **default/strict** path does **not** trust the private CA → TLS verification fails.
- The **custom-ca** path uses a dedicated CA **only** for that destination → it works.

## Quick Run

```bash
./ossm/uc9-verify.sh east
```

For WEST:

```bash
./ossm/uc9-verify.sh west
```

Useful variables:

- `AUTO_ENABLE_DNS_CAPTURE=true`: auto-habilita DNS capture si está apagado
- `KEEP_RESOURCES_ON_FAIL=true`: deja recursos para inspección
- `NO_PAUSE=true`: non-interactive mode
- `CUSTOM_CA_HEADER=x-bank-custom-ca`: header that enables the custom-CA path (default: `x-bank-custom-ca: true`)
- `BUILD_MODE=binary|git|prebuilt`: how images are obtained (default: `binary`)
  - `binary`: uses `start-build --from-dir` (uploads local dir; good for local testing without pushing)
  - `git`: build happens in-cluster from a Git repo (avoids local upload; requires the remote repo contains `ossm/uc9/...`)
  - `prebuilt`: no build; uses `CUSTOM_CERT_SERVER_IMAGE` and `HAPROXY_IMAGE`
- `GIT_REPO_URL=https://...`: forces the repo URL for `BUILD_MODE=git`
- `IMAGE_BUILD_NS=uc-images`: **non-ambient** namespace for Builds (keeps build pods out of Kiali graphs)
- `KIALI_DEMO=true`: deploys a background traffic generator and **skips cleanup** (better for Kiali demos)
- `TRAFFIC_PERIOD_SEC=2`: traffic generator period (seconds)

## Expected Results

| Request | Header `x-bank-custom-ca` | Result |
|---|---:|---|
| `GET http://customcert.bank.demo/` | *(none)* | **FAIL** |
| `GET http://customcert.bank.demo/` | `true` | **200 OK** |

## What to verify in Kiali Traces (expected)

When you test UC9, you should see **two distinct operations** (two connectors) with different results:

- **Strict path (expected failure)**:
  - **Operation**: `custom-cert-connector-strict.egress-custom-cert.svc.cluster.local:8080/*`
  - **Response status**: **503**
- **Custom CA path (expected success)**:
  - **Operation**: `custom-cert-connector-customca.egress-custom-cert.svc.cluster.local:8080/*`
  - **Response status**: **200**

This is the core validation: **only** the custom-CA connector trusts the private CA.

## Kiali demo (steps)

1) Run UC9 in demo mode:

```bash
NO_PAUSE=true KIALI_DEMO=true ./ossm/uc9-verify.sh east
```

2) Open Kiali and look at the **Graph** (Workload graph) for these namespaces:

- `bookinfo` (cliente/generador; o el que uses como `TRAFFIC_NS`)
- `egress-custom-cert` (waypoint + connectors)
- `custom-cert-backend` (backend TLS con CA privada)

3) Wait 1–2 minutes and select “Last 1m/5m”. You should see traffic alternating between:

- **strict connector** (TLS verification errors → 503)
- **custom-ca connector** (success → 200)

