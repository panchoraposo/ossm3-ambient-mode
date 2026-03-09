#!/bin/bash

# Configuration
NAMESPACE="bookinfo"
ROUTE_NAME="bookinfo-gateway"
APP_PATH="/productpage"

echo "------------------------------------------------"
echo "Discovering Bookinfo Routes (east2 + west2)..."

# 1. Get the Hosts directly from the OpenShift Routes
HOST_EAST=$(oc --context east2 get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)
HOST_WEST=$(oc --context west2 get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || true)

# 2. Validation
if [ -z "$HOST_EAST" ]; then
  echo "Error: Could not find route '$ROUTE_NAME' in namespace '$NAMESPACE' using context 'east2'."
  exit 1
fi
if [ -z "$HOST_WEST" ]; then
  echo "Error: Could not find route '$ROUTE_NAME' in namespace '$NAMESPACE' using context 'west2'."
  exit 1
fi

# 3. Construct the URL
URL_EAST="http://${HOST_EAST}${APP_PATH}"
URL_WEST="http://${HOST_WEST}${APP_PATH}"

echo "East URL: $URL_EAST"
echo "West URL: $URL_WEST"
echo "Generating traffic to BOTH clusters... (CTRL+C to stop)"
echo "------------------------------------------------"

traffic_loop() {
  local name="$1"
  local url="$2"
  while true; do
    local code ts
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" || echo "000")
    ts=$(date +"%H:%M:%S")
    echo "[$ts] $name $code"
    sleep 0.25
  done
}

# 4. Traffic Loop (parallel)
traffic_loop "east2" "$URL_EAST" &
PID_EAST=$!
traffic_loop "west2" "$URL_WEST" &
PID_WEST=$!

cleanup() {
  kill "$PID_EAST" "$PID_WEST" 2>/dev/null || true
  wait "$PID_EAST" "$PID_WEST" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

wait