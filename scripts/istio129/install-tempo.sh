#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

need kubectl
need oc
need python3

require_context "$CTX_ACM"
require_context "$CTX_EAST"
require_context "$CTX_WEST"

TEMPO_NS="${TEMPO_NS:-${ISTIO_NS}}"
TEMPO_SVC_NAME="${TEMPO_SVC_NAME:-tempo}"
TEMPO_IMAGE="${TEMPO_IMAGE:-docker.io/grafana/tempo:2.6.1}"
TEMPO_QUERY_PORT="${TEMPO_QUERY_PORT:-3200}"
TEMPO_OTLP_GRPC_PORT="${TEMPO_OTLP_GRPC_PORT:-4317}"
TEMPO_OTLP_HTTP_PORT="${TEMPO_OTLP_HTTP_PORT:-4318}"

OTELCOL_NS="${OTELCOL_NS:-${ISTIO_NS}}"
OTELCOL_SVC_NAME="${OTELCOL_SVC_NAME:-otel-collector}"
OTELCOL_IMAGE="${OTELCOL_IMAGE:-docker.io/otel/opentelemetry-collector-contrib:0.104.0}"

ensure_ns() {
  local ctx="$1" ns="$2"
  kubectl --context "$ctx" get ns "$ns" >/dev/null 2>&1 || kubectl --context "$ctx" create ns "$ns" >/dev/null
}

deploy_tempo_on_hub() {
  log "Deploying Tempo on ${CTX_ACM}/${TEMPO_NS}..."
  ensure_ns "$CTX_ACM" "$TEMPO_NS"

  kubectl --context "$CTX_ACM" -n "$TEMPO_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
data:
  tempo.yaml: |
    auth_enabled: false
    server:
      http_listen_port: ${TEMPO_QUERY_PORT}
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
            http:
    ingester:
      # Make traces searchable quickly for demos/Kiali.
      trace_idle_period: 10s
      max_block_duration: 30s
      lifecycler:
        ring:
          kvstore:
            store: inmemory
          replication_factor: 1
    compactor:
      compaction:
        compacted_block_retention: 1h
    storage:
      trace:
        backend: local
        local:
          path: /var/tempo/traces
        wal:
          path: /var/tempo/wal
    overrides:
      defaults:
        ingestion:
          burst_size_bytes: 20000000
          rate_limit_bytes: 20000000
EOF

  kubectl --context "$CTX_ACM" -n "$TEMPO_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TEMPO_SVC_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${TEMPO_SVC_NAME}
  template:
    metadata:
      labels:
        app: ${TEMPO_SVC_NAME}
    spec:
      containers:
      - name: tempo
        image: ${TEMPO_IMAGE}
        args: ["-config.file=/etc/tempo/tempo.yaml"]
        ports:
        - name: http
          containerPort: ${TEMPO_QUERY_PORT}
        - name: otlp-grpc
          containerPort: ${TEMPO_OTLP_GRPC_PORT}
        - name: otlp-http
          containerPort: ${TEMPO_OTLP_HTTP_PORT}
        readinessProbe:
          httpGet:
            path: /ready
            port: http
          periodSeconds: 10
          timeoutSeconds: 2
        livenessProbe:
          httpGet:
            path: /ready
            port: http
          periodSeconds: 20
          timeoutSeconds: 2
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: cfg
          mountPath: /etc/tempo
        - name: data
          mountPath: /var/tempo
      volumes:
      - name: cfg
        configMap:
          name: tempo-config
      - name: data
        emptyDir: {}
EOF

  kubectl --context "$CTX_ACM" -n "$TEMPO_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${TEMPO_SVC_NAME}
spec:
  selector:
    app: ${TEMPO_SVC_NAME}
  ports:
  - name: http
    port: ${TEMPO_QUERY_PORT}
    targetPort: http
  - name: otlp-grpc
    port: ${TEMPO_OTLP_GRPC_PORT}
    targetPort: otlp-grpc
  - name: otlp-http
    port: ${TEMPO_OTLP_HTTP_PORT}
    targetPort: otlp-http
EOF

  # Query/debug route (optional)
  kubectl --context "$CTX_ACM" -n "$TEMPO_NS" apply -f - >/dev/null <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: tempo
spec:
  to:
    kind: Service
    name: ${TEMPO_SVC_NAME}
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

  # OTLP/HTTP ingest route (collector -> tempo)
  kubectl --context "$CTX_ACM" -n "$TEMPO_NS" apply -f - >/dev/null <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: tempo-otlp
spec:
  to:
    kind: Service
    name: ${TEMPO_SVC_NAME}
  port:
    targetPort: otlp-http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

  oc --context "$CTX_ACM" -n "$TEMPO_NS" rollout status "deploy/${TEMPO_SVC_NAME}" --timeout=300s >/dev/null

  local tempo_host otlp_host
  tempo_host="$(oc --context "$CTX_ACM" -n "$TEMPO_NS" get route tempo -o jsonpath='{.spec.host}')"
  otlp_host="$(oc --context "$CTX_ACM" -n "$TEMPO_NS" get route tempo-otlp -o jsonpath='{.spec.host}')"
  log "Tempo query route: https://${tempo_host}"
  log "Tempo OTLP/HTTP route: https://${otlp_host}"
}

deploy_otel_collectors_on_remotes() {
  local otlp_host
  otlp_host="$(oc --context "$CTX_ACM" -n "$TEMPO_NS" get route tempo-otlp -o jsonpath='{.spec.host}')"
  [[ -n "${otlp_host:-}" ]] || die "could not resolve tempo-otlp route host on ${CTX_ACM}/${TEMPO_NS}"

  for ctx in "$CTX_EAST" "$CTX_WEST"; do
    log "Deploying OpenTelemetry Collector on ${ctx}/${OTELCOL_NS} (export -> acm2 Tempo)..."
    ensure_ns "$ctx" "$OTELCOL_NS"

    kubectl --context "$ctx" -n "$OTELCOL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
data:
  config.yaml: |
    receivers:
      zipkin:
        endpoint: 0.0.0.0:9411
    processors:
      batch: {}
    exporters:
      otlphttp:
        # otlphttp exporter appends /v1/traces automatically.
        endpoint: https://${otlp_host}
        tls:
          insecure_skip_verify: true
    service:
      pipelines:
        traces:
          receivers: [zipkin]
          processors: [batch]
          exporters: [otlphttp]
EOF

    kubectl --context "$ctx" -n "$OTELCOL_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${OTELCOL_SVC_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${OTELCOL_SVC_NAME}
  template:
    metadata:
      labels:
        app: ${OTELCOL_SVC_NAME}
    spec:
      containers:
      - name: otelcol
        image: ${OTELCOL_IMAGE}
        args: ["--config=/conf/config.yaml"]
        ports:
        - name: zipkin
          containerPort: 9411
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: conf
          mountPath: /conf
      volumes:
      - name: conf
        configMap:
          name: otel-collector-config
EOF

    kubectl --context "$ctx" -n "$OTELCOL_NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${OTELCOL_SVC_NAME}
spec:
  selector:
    app: ${OTELCOL_SVC_NAME}
  ports:
  - name: zipkin
    port: 9411
    targetPort: zipkin
EOF

    kubectl --context "$ctx" -n "$OTELCOL_NS" rollout status "deploy/${OTELCOL_SVC_NAME}" --timeout=300s >/dev/null
  done
}

disable_mtls_to_otel_collector() {
  local ctx="$1"
  # The collector is not part of the mesh and does not speak Istio mTLS.
  kubectl --context "$ctx" -n "$ISTIO_NS" apply -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: otel-collector-plaintext
  namespace: istio-system
spec:
  host: otel-collector.istio-system.svc.cluster.local
  trafficPolicy:
    tls:
      mode: DISABLE
EOF
}

main() {
  log "=== Install Tempo tracing (hub Tempo + remote OTLP collectors) ==="
  log "Hub: ${CTX_ACM}"
  log "Remotes: ${CTX_EAST}, ${CTX_WEST}"
  log ""

  deploy_tempo_on_hub
  deploy_otel_collectors_on_remotes

  disable_mtls_to_otel_collector "$CTX_EAST"
  disable_mtls_to_otel_collector "$CTX_WEST"

  log ""
  log "Done. Next:"
  log "  - Ensure Istio is configured to export Zipkin spans to the collector:"
  log "    CTX_EAST=${CTX_EAST} CTX_WEST=${CTX_WEST} ./scripts/istio129/install.sh"
  log "  - Re-run hub observability so Kiali enables Tempo tracing:"
  log "    TRACING_ENABLED=true CTX_ACM=${CTX_ACM} CTX_EAST=${CTX_EAST} CTX_WEST=${CTX_WEST} ./scripts/istio129/install-acm2-observability.sh"
  log "  - Then run a demo (traffic-shift or failover) and open Kiali -> Traces."
}

main "$@"

