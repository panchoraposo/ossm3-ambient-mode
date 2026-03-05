#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="${CACHE_DIR:-${ROOT_DIR}/.cache}"
ISTIO_CACHE_DIR="${ISTIO_CACHE_DIR:-${CACHE_DIR}/istio}"

CTX_EAST="${CTX_EAST:-east2}"
CTX_WEST="${CTX_WEST:-west2}"
CTX_ACM="${CTX_ACM:-acm2}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.0}"
MESH_ID="${MESH_ID:-mesh1}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_context() {
  local ctx="$1"
  kubectl config get-contexts "$ctx" >/dev/null 2>&1 || die "kubeconfig context not found: ${ctx}"
}

os_arch() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  # Istio release artifacts use "osx" for macOS, not "darwin"
  [[ "$os" == "darwin" ]] && os="osx"
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
  esac
  echo "${os}-${arch}"
}

istio_minor() {
  echo "$ISTIO_VERSION" | awk -F. '{print $1"."$2}'
}

istioctl_path() {
  echo "${ISTIO_CACHE_DIR}/${ISTIO_VERSION}/istioctl"
}

download_istioctl() {
  need curl
  need tar

  local dst dir tgz url oa
  dst="$(istioctl_path)"
  if [[ -x "$dst" ]]; then
    log "istioctl already present: $dst"
    return 0
  fi

  oa="$(os_arch)"
  dir="$(dirname "$dst")"
  mkdir -p "$dir"

  # Istio release tarballs are: istio-<version>-<os>-<arch>.tar.gz
  tgz="${dir}/istio-${ISTIO_VERSION}-${oa}.tar.gz"
  url="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-${oa}.tar.gz"

  log "Downloading istioctl ${ISTIO_VERSION} (${oa})..."
  curl -fsSL "$url" -o "$tgz"
  tar -xzf "$tgz" -C "$dir"
  mv "${dir}/istio-${ISTIO_VERSION}/bin/istioctl" "$dst"
  chmod +x "$dst"
  rm -rf "${dir}/istio-${ISTIO_VERSION}" "$tgz"
  log "Installed istioctl: $dst"
}

istioctl() {
  "$(istioctl_path)" "$@"
}

apply_yaml() {
  local ctx="$1"
  local ns="$2"
  shift 2
  if [[ -n "$ns" ]]; then
    kubectl --context "$ctx" apply -n "$ns" -f - "$@"
  else
    kubectl --context "$ctx" apply -f - "$@"
  fi
}

wait_ready() {
  local ctx="$1" ns="$2" kind="$3" name="$4" timeout="${5:-180s}"
  kubectl --context "$ctx" -n "$ns" rollout status "${kind}/${name}" "--timeout=${timeout}"
}

