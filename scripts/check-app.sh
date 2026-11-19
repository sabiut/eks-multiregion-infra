#!/usr/bin/env bash
# Ask one region's application a question, and be sure it is THAT region answering.
#
#   scripts/check-app.sh ap-southeast-1 read      # the database answers a read
#   scripts/check-app.sh ap-southeast-1 write     # a write is stored (the count goes up)
#   scripts/check-app.sh ap-southeast-2 refused   # a write is refused (the region is fenced)
#
# It reaches the frontend through its own port-forward on a free local port, waits for the
# forward to be ready, checks which region answered, runs the check, and closes the forward.
# It goes through the cluster, not the load balancer or the accelerator, so it works for a
# region that takes no traffic. Exit code 0 means the check passed.
#
# CHECK_URL=http://host:port skips the port-forward (used to test this script).
set -euo pipefail

region=${1:?usage: check-app.sh <region> <read|write|refused>}
check=${2:?usage: check-app.sh <region> <read|write|refused>}
namespace=${NAMESPACE:-demo}
context=${KUBE_CONTEXT:-lab-$region}

fail() { echo "FAIL  $region $check: $*" >&2; exit 1; }
# Body on the first lines, HTTP status on the last. Never fails on an HTTP error status.
request() { curl -sS -m 10 -w '\n%{http_code}' "$@" || echo $'\n000'; }
body()    { sed '$d' <<<"$1"; }
status()  { tail -n 1 <<<"$1"; }

if [[ -n ${CHECK_URL:-} ]]; then
  base=$CHECK_URL
else
  # A port nothing else is using, so two checks can never talk to each other's forward.
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  kubectl --context "$context" -n "$namespace" port-forward svc/demo-web "$port:80" >/dev/null 2>&1 &
  forward=$!
  trap 'kill "$forward" 2>/dev/null || true' EXIT
  base=http://127.0.0.1:$port
  for _ in $(seq 1 30); do
    kill -0 "$forward" 2>/dev/null || fail "the port-forward to $context stopped"
    curl -fsS -m 2 "$base/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS -m 2 "$base/healthz" >/dev/null 2>&1 || fail "the port-forward to $context never became ready"
fi

# Which region is answering? Asked of the backend, through the frontend.
info=$(request "$base/api/info")
[[ $(status "$info") == 200 ]] || fail "/api/info returned HTTP $(status "$info")"
answered=$(body "$info" | jq -r '.region')
[[ $answered == "$region" ]] || fail "expected $region to answer, but $answered did"

visits() { # method -> prints the count; fails unless the database stored it
  local reply; reply=$(request -X "$1" "$base/api/visits")
  [[ $(status "$reply") == 200 ]] || fail "$1 /api/visits returned HTTP $(status "$reply"): $(body "$reply")"
  [[ $(body "$reply" | jq -r '.store') == postgres ]] || fail "the count is not in the database: $(body "$reply")"
  body "$reply" | jq -r '.visits'
}

case $check in
  read)
    count=$(visits GET)
    echo "OK    $region read: $count visits, from the database"
    ;;
  write)
    before=$(visits GET)
    after=$(visits POST)
    (( after > before )) || fail "the count did not go up ($before -> $after)"
    echo "OK    $region write: $before -> $after, stored in the database"
    ;;
  refused)
    reply=$(request -X POST "$base/api/visits")
    [[ $(status "$reply") == 503 ]] || fail "the write was NOT refused: HTTP $(status "$reply") $(body "$reply")"
    echo "OK    $region refused the write: $(body "$reply" | jq -c .)"
    ;;
  *) fail "unknown check: $check" ;;
esac
