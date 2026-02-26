#!/bin/bash
set -euo pipefail

#
# Cleanup kubeconfig entries for clusters that no longer exist.
#
# Default behavior is DRY RUN (no changes). Use --apply to perform deletions.
#
# What it removes (from your kubeconfig):
# - contexts
# - clusters (only if no remaining context references them)
# - users    (only if no remaining context references them)
#
# How "stale" is detected:
# - `oc --context <ctx> --request-timeout=3s whoami`
# - If the output indicates a connection failure (DNS/TCP/TLS), it is considered stale.
# - If the output indicates Unauthorized/Forbidden, it is considered reachable and will NOT be removed.
#

APPLY=false
REQUEST_TIMEOUT="3s"
CHECK_CONSOLE=false
FORCE=false

usage() {
  cat <<'EOF'
Usage:
  ./cleanup_clusters.sh [--apply] [--timeout 3s] [--check-console] [--force] [context1 context2 ...]

Examples:
  # Dry run: check all contexts in kubeconfig
  ./cleanup_clusters.sh

  # Dry run: only evaluate these contexts
  ./cleanup_clusters.sh east west acm

  # Apply deletions for stale contexts
  ./cleanup_clusters.sh --apply

  # Apply deletions with a custom request timeout
  ./cleanup_clusters.sh --apply --timeout 5s

  # Treat contexts as stale if the OpenShift console is unreachable (best-effort)
  ./cleanup_clusters.sh --check-console

  # Force-delete specific contexts (requires explicit context names)
  ./cleanup_clusters.sh --apply --force east2 west2
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value (e.g. 3s)"
      REQUEST_TIMEOUT="$2"
      shift 2
      ;;
    --check-console)
      CHECK_CONSOLE=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      break
      ;;
  esac
done

if ! command -v oc >/dev/null 2>&1; then
  die "'oc' CLI not found in PATH"
fi

if ! command -v curl >/dev/null 2>&1; then
  die "'curl' not found in PATH"
fi

get_all_contexts() {
  oc config get-contexts -o name 2>/dev/null || true
}

get_context_server() {
  local ctx="$1"
  oc --context "$ctx" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

derive_console_url_from_server() {
  # Best-effort derivation:
  # - API:    https://api.<cluster-domain>:6443  -> <cluster-domain>
  # - API:    https://api-<cluster-domain>:6443 -> <cluster-domain>
  # - Console https://console-openshift-console.apps.<cluster-domain>
  local server="$1"
  local host domain

  host="${server#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  host="${host%%:*}"

  domain="$host"
  if [[ "$domain" == api.* ]]; then
    domain="${domain#api.}"
  elif [[ "$domain" == api-* ]]; then
    domain="${domain#api-}"
  fi

  if [[ -z "$domain" ]]; then
    return 1
  fi

  printf 'https://console-openshift-console.apps.%s\n' "$domain"
}

get_context_cluster() {
  local ctx="$1"
  oc config view -o jsonpath="{range .contexts[?(@.name==\"${ctx}\")]}{.context.cluster}{end}" 2>/dev/null || true
}

get_context_user() {
  local ctx="$1"
  oc config view -o jsonpath="{range .contexts[?(@.name==\"${ctx}\")]}{.context.user}{end}" 2>/dev/null || true
}

context_reachable_status() {
  # Prints:
  # - "ok"             if API is reachable (HTTP 200)
  # - "auth"           if API is reachable but requires auth (HTTP 401/403)
  # - "stale:<reason>" if connection failure (DNS/TCP/TLS -> curl HTTP 000)
  local ctx="$1"
  local server
  server="$(get_context_server "$ctx")"
  if [[ -z "$server" ]]; then
    printf 'stale:missing API server for context\n'
    return 0
  fi

  local url code
  url="${server%/}/readyz"
  code="$(curl -k -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time "${REQUEST_TIMEOUT%s}" "$url" 2>/dev/null || echo 000)"

  case "$code" in
    200)
      if [[ "$CHECK_CONSOLE" == "true" ]]; then
        local console_url console_code
        console_url="$(derive_console_url_from_server "$server" || true)"
        if [[ -n "$console_url" ]]; then
          console_code="$(curl -k -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time "${REQUEST_TIMEOUT%s}" "$console_url" 2>/dev/null || echo 000)"
          if [[ "$console_code" == "000" ]] || [[ "$console_code" == 5* ]]; then
            printf 'stale:console unreachable (%s)\n' "$console_url"
            return 0
          fi
        fi
      fi
      printf 'ok\n'
      ;;
    401|403)
      if [[ "$CHECK_CONSOLE" == "true" ]]; then
        local console_url console_code
        console_url="$(derive_console_url_from_server "$server" || true)"
        if [[ -n "$console_url" ]]; then
          console_code="$(curl -k -sS -o /dev/null -w "%{http_code}" --connect-timeout 2 --max-time "${REQUEST_TIMEOUT%s}" "$console_url" 2>/dev/null || echo 000)"
          if [[ "$console_code" == "000" ]] || [[ "$console_code" == 5* ]]; then
            printf 'stale:console unreachable (%s)\n' "$console_url"
            return 0
          fi
        fi
      fi
      printf 'auth\n'
      ;;
    000)
      printf 'stale:cannot reach API server (%s)\n' "$server"
      ;;
    5*)
      printf 'stale:API server error (%s) HTTP %s\n' "$server" "$code"
      ;;
    *)
      # Any other HTTP status still proves the endpoint is reachable.
      printf 'auth\n'
      ;;
  esac
}

contexts_to_check=()
if [[ $# -gt 0 ]]; then
  contexts_to_check=("$@")
else
  while IFS= read -r ctx; do
    [[ -n "$ctx" ]] && contexts_to_check+=("$ctx")
  done < <(get_all_contexts)
fi

if [[ ${#contexts_to_check[@]} -eq 0 ]]; then
  log "No contexts found."
  exit 0
fi

stale_contexts=()
if [[ "$FORCE" == "true" ]]; then
  if [[ "$APPLY" != "true" ]]; then
    die "--force requires --apply"
  fi
  if [[ $# -eq 0 ]]; then
    die "--force requires explicit context names (it will not run against all contexts)"
  fi
  log "Force mode enabled. Contexts will be deleted without reachability checks."
  stale_contexts=("${contexts_to_check[@]}")
else
  log "Evaluating contexts (timeout: $REQUEST_TIMEOUT)."
  for ctx in "${contexts_to_check[@]}"; do
    if [[ -z "$ctx" ]]; then
      continue
    fi

    status="$(context_reachable_status "$ctx")"
    case "$status" in
      ok)
        log "  [keep] $ctx (reachable)"
        ;;
      auth)
        log "  [keep] $ctx (reachable, but not authenticated)"
        ;;
      stale:*)
        reason="${status#stale:}"
        log "  [stale] $ctx"
        log "          $reason"
        stale_contexts+=("$ctx")
        ;;
      *)
        log "  [keep] $ctx (unknown status: $status)"
        ;;
    esac
  done
fi

if [[ ${#stale_contexts[@]} -eq 0 ]]; then
  log "No stale contexts detected."
  exit 0
fi

log ""
log "Stale contexts detected:"
for ctx in "${stale_contexts[@]}"; do
  log "  - $ctx"
done

if [[ "$APPLY" != "true" ]]; then
  log ""
  log "Dry run only. Re-run with --apply to delete them from your kubeconfig."
  exit 0
fi

log ""
log "Applying kubeconfig cleanup."

# Delete contexts first.
for ctx in "${stale_contexts[@]}"; do
  log "Deleting context: $ctx"
  oc config delete-context "$ctx" >/dev/null 2>&1 || true
done

# Optionally delete clusters/users that are no longer referenced by any remaining context.
remaining_contexts=()
while IFS= read -r ctx; do
  [[ -n "$ctx" ]] && remaining_contexts+=("$ctx")
done < <(get_all_contexts)

cluster_ref_count() {
  local target="$1"
  local count=0
  local c cl
  for c in "${remaining_contexts[@]}"; do
    cl="$(get_context_cluster "$c")"
    if [[ -n "$cl" && "$cl" == "$target" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s' "$count"
}

user_ref_count() {
  local target="$1"
  local count=0
  local c u
  for c in "${remaining_contexts[@]}"; do
    u="$(get_context_user "$c")"
    if [[ -n "$u" && "$u" == "$target" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s' "$count"
}

clusters_to_maybe_delete=()
users_to_maybe_delete=()
for ctx in "${stale_contexts[@]}"; do
  cl="$(get_context_cluster "$ctx")"
  u="$(get_context_user "$ctx")"
  [[ -n "$cl" ]] && clusters_to_maybe_delete+=("$cl")
  [[ -n "$u" ]] && users_to_maybe_delete+=("$u")
done

# Deduplicate arrays (portable-ish, no associative arrays required)
dedup_lines() { awk 'NF && !seen[$0]++'; }

clusters_to_maybe_delete_dedup=()
while IFS= read -r line; do
  [[ -n "$line" ]] && clusters_to_maybe_delete_dedup+=("$line")
done < <(printf '%s\n' "${clusters_to_maybe_delete[@]}" | dedup_lines || true)
clusters_to_maybe_delete=("${clusters_to_maybe_delete_dedup[@]}")

users_to_maybe_delete_dedup=()
while IFS= read -r line; do
  [[ -n "$line" ]] && users_to_maybe_delete_dedup+=("$line")
done < <(printf '%s\n' "${users_to_maybe_delete[@]}" | dedup_lines || true)
users_to_maybe_delete=("${users_to_maybe_delete_dedup[@]}")

for cl in "${clusters_to_maybe_delete[@]}"; do
  if [[ "$(cluster_ref_count "$cl")" -eq 0 ]]; then
    log "Deleting cluster entry: $cl"
    oc config delete-cluster "$cl" >/dev/null 2>&1 || true
  else
    log "Keeping cluster entry (still referenced): $cl"
  fi
done

for u in "${users_to_maybe_delete[@]}"; do
  if [[ "$(user_ref_count "$u")" -eq 0 ]]; then
    log "Deleting user entry: $u"
    oc config unset "users.${u}" >/dev/null 2>&1 || true
  else
    log "Keeping user entry (still referenced): $u"
  fi
done

log "Done."

