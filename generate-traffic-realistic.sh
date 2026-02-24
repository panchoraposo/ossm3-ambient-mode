#!/bin/bash
set -euo pipefail

# Realistic-ish traffic generator for the Bookinfo demo.
#
# - Discovers Bookinfo gateway Routes from OpenShift (contexts: east, west)
# - Generates mixed traffic (HTML + APIs) with concurrency, jitter, and bursts
# - Prints periodic stats so the Kiali traffic graph looks "alive"
#
# Requirements: oc, curl, bash

NAMESPACE="bookinfo"
ROUTE_NAME="bookinfo-gateway"

CTX_EAST="east"
CTX_WEST="west"

WORKERS_PER_CLUSTER=8
INTERVAL_SECONDS=2
DURATION_SECONDS=0   # 0 = run forever
VERBOSE=false

usage() {
  cat <<'EOF'
Usage:
  ./generate-traffic-realistic.sh [options]

Options:
  --workers N        Workers per cluster (default: 8)
  --interval N       Stats print interval seconds (default: 2)
  --duration N       Stop after N seconds (default: 0 = forever)
  --verbose          Print every request line (default: stats only)
  -h, --help         Show help

Examples:
  ./generate-traffic-realistic.sh
  ./generate-traffic-realistic.sh --workers 20 --interval 1
  ./generate-traffic-realistic.sh --duration 120
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)
      WORKERS_PER_CLUSTER="${2:-}"
      shift 2
      ;;
    --interval)
      INTERVAL_SECONDS="${2:-}"
      shift 2
      ;;
    --duration)
      DURATION_SECONDS="${2:-}"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc not found in PATH" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl not found in PATH" >&2
  exit 1
fi

echo "------------------------------------------------"
echo "Discovering Bookinfo Routes (${CTX_EAST} + ${CTX_WEST})..."

HOST_EAST="$(oc --context "${CTX_EAST}" get route "${ROUTE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
HOST_WEST="$(oc --context "${CTX_WEST}" get route "${ROUTE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"

if [[ -z "${HOST_EAST}" ]]; then
  echo "ERROR: Could not find route '${ROUTE_NAME}' in namespace '${NAMESPACE}' using context '${CTX_EAST}'." >&2
  exit 1
fi
if [[ -z "${HOST_WEST}" ]]; then
  echo "ERROR: Could not find route '${ROUTE_NAME}' in namespace '${NAMESPACE}' using context '${CTX_WEST}'." >&2
  exit 1
fi

BASE_EAST="http://${HOST_EAST}"
BASE_WEST="http://${HOST_WEST}"

echo "East base URL: ${BASE_EAST}"
echo "West base URL: ${BASE_WEST}"
echo "Workers/cluster: ${WORKERS_PER_CLUSTER}"
echo "Stats interval:  ${INTERVAL_SECONDS}s"
if [[ "${DURATION_SECONDS}" != "0" ]]; then
  echo "Duration:        ${DURATION_SECONDS}s"
else
  echo "Duration:        forever (CTRL+C to stop)"
fi
echo "------------------------------------------------"

tmpdir="$(mktemp -d)"
fifo="${tmpdir}/events.fifo"
mkfifo "${fifo}"
# Open FIFO in read/write mode to avoid open() deadlocks on macOS.
exec 3<>"${fifo}"

cleanup() {
  # best-effort cleanup
  pkill -P $$ >/dev/null 2>&1 || true
  exec 3>&- 2>/dev/null || true
  rm -rf "${tmpdir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

rand_hex() {
  # bash 3.2 friendly
  printf '%04x%04x%04x' "${RANDOM}" "${RANDOM}" "${RANDOM}"
}

pick_user_agent() {
  case $((RANDOM % 6)) in
    0) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36" ;;
    1) echo "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36" ;;
    2) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36" ;;
    3) echo "curl/8.7.1" ;;
    4) echo "k6/0.49 (demo)" ;;
    *) echo "Mozilla/5.0 (iPhone; CPU iPhone OS 17_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" ;;
  esac
}

pick_path() {
  # Weighted distribution (0-99)
  # More productpage and API calls, plus some direct service calls.
  r=$((RANDOM % 100))
  if [[ $r -lt 40 ]]; then
    echo "/productpage"
  elif [[ $r -lt 62 ]]; then
    # productpage API that triggers internal calls
    # productId 0 is always valid; sprinkle some invalid IDs to create "real" noise.
    if [[ $((RANDOM % 10)) -eq 0 ]]; then
      echo "/api/v1/products/$((RANDOM % 20))"
    else
      echo "/api/v1/products/0"
    fi
  elif [[ $r -lt 76 ]]; then
    echo "/details/0"
  elif [[ $r -lt 88 ]]; then
    echo "/reviews/0"
  elif [[ $r -lt 96 ]]; then
    echo "/ratings/0"
  elif [[ $r -lt 98 ]]; then
    echo "/login"
  else
    # occasional cache-buster/static/noise
    echo "/static/nonexistent.css?cb=$(rand_hex)"
  fi
}

do_request() {
  local cluster="$1"
  local base="$2"
  local worker="$3"
  local path ua rid url code ms

  path="$(pick_path)"
  ua="$(pick_user_agent)"
  rid="$(rand_hex)"
  url="${base}${path}"

  # time_total is seconds with decimals; convert to ms using awk
  out="$(curl -sS -o /dev/null -w "%{http_code} %{time_total}" \
    -H "User-Agent: ${ua}" \
    -H "X-Request-Id: ${rid}" \
    -H "Accept: */*" \
    --connect-timeout 2 --max-time 10 \
    "${url}" 2>/dev/null || echo "000 0")"

  code="${out%% *}"
  sec="${out#* }"
  ms="$(awk -v s="${sec}" 'BEGIN { printf("%d", (s+0)*1000) }')"

  if [[ "${VERBOSE}" == "true" ]]; then
    ts="$(date +"%H:%M:%S")"
    printf '[%s] %s w=%s %s %s %sms\n' "${ts}" "${cluster}" "${worker}" "${code}" "${path}" "${ms}"
  fi

  printf '%s %s %s\n' "${cluster}" "${code}" "${ms}" >&3
}

worker_loop() {
  local cluster="$1"
  local base="$2"
  local worker="$3"
  local burst_counter=0

  while true; do
    do_request "${cluster}" "${base}" "${worker}"

    # "think time": mostly short, sometimes longer
    if [[ $((RANDOM % 20)) -eq 0 ]]; then
      sleep 1
    else
      # 20ms-250ms jitter
      us=$((20000 + (RANDOM % 230000)))
      sleep "$(awk -v u="${us}" 'BEGIN { printf("%.3f", u/1000000) }')"
    fi

    # burst mode: occasionally generate a small burst
    burst_counter=$((burst_counter + 1))
    if [[ $((burst_counter % 50)) -eq 0 ]]; then
      n=$((10 + (RANDOM % 25)))
      i=0
      while [[ $i -lt $n ]]; do
        do_request "${cluster}" "${base}" "${worker}"
        i=$((i + 1))
      done
    fi
  done
}

stats_loop() {
  python3 -u -c '
import sys, time
interval = float(sys.argv[1])

def cls(code: str) -> str:
    if code.startswith("2"):
        return "2xx"
    if code.startswith("3"):
        return "3xx"
    if code.startswith("4"):
        return "4xx"
    if code.startswith("5"):
        return "5xx"
    return "000"

def reset():
    return {"cnt": {}, "ok": {}, "e4": {}, "e5": {}, "e0": {}, "summs": {}, "minms": {}, "maxms": {}, "start": time.time()}

s = reset()
for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) < 3:
        continue
    cluster, code, ms_s = parts[0], parts[1], parts[2]
    try:
        ms = int(float(ms_s))
    except Exception:
        ms = 0

    s["cnt"][cluster] = s["cnt"].get(cluster, 0) + 1
    k = cls(code)
    if k == "2xx":
        s["ok"][cluster] = s["ok"].get(cluster, 0) + 1
    elif k == "4xx":
        s["e4"][cluster] = s["e4"].get(cluster, 0) + 1
    elif k == "5xx":
        s["e5"][cluster] = s["e5"].get(cluster, 0) + 1
    else:
        s["e0"][cluster] = s["e0"].get(cluster, 0) + 1

    s["summs"][cluster] = s["summs"].get(cluster, 0) + ms
    s["minms"][cluster] = ms if cluster not in s["minms"] else min(s["minms"][cluster], ms)
    s["maxms"][cluster] = ms if cluster not in s["maxms"] else max(s["maxms"][cluster], ms)

    if time.time() - s["start"] >= interval:
        ts = time.strftime("%H:%M:%S", time.localtime())
        for c in sorted(s["cnt"].keys()):
            cnt = s["cnt"].get(c, 0)
            avg = int((s["summs"].get(c, 0) / cnt) if cnt else 0)
            ok = s["ok"].get(c, 0)
            e4 = s["e4"].get(c, 0)
            e5 = s["e5"].get(c, 0)
            e0 = s["e0"].get(c, 0)
            mn = s["minms"].get(c, 0)
            mx = s["maxms"].get(c, 0)
            print(f"[{ts}] {c} req={cnt} ok={ok} 4xx={e4} 5xx={e5} 000={e0} avg={avg}ms min={mn}ms max={mx}ms")
        sys.stdout.flush()
        s = reset()
' "${INTERVAL_SECONDS}"
}

stats_loop <&3 &
STATS_PID=$!

i=1
while [[ $i -le "${WORKERS_PER_CLUSTER}" ]]; do
  worker_loop "east" "${BASE_EAST}" "${i}" &
  worker_loop "west" "${BASE_WEST}" "${i}" &
  i=$((i + 1))
done

if [[ "${DURATION_SECONDS}" != "0" ]]; then
  end=$((SECONDS + DURATION_SECONDS))
  while [[ "${SECONDS}" -lt "${end}" ]]; do
    sleep 1
  done
  exit 0
fi

wait "${STATS_PID}"

