#!/usr/bin/env bash
# Post-deploy smoke test: smoke.sh <url> [expected-git-sha]
#  1. wait until the hostname resolves - asking Route 53's authoritative servers,
#     so a too-early lookup can't leave a cached NXDOMAIN on the runner
#  2. HTTPS answers and reports the expected version (else the rollout rolled back)
#  3. /readyz proves the database path (skipped when the DB is disabled)
set -euo pipefail

URL="$1"
EXPECTED="${2:-}"
HOST="${URL#https://}"
HOST="${HOST%%/*}"
ZONE="${HOST#*.}"

command -v dig > /dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq dnsutils; }
NS=$(dig +short NS "$ZONE" | head -1)
echo "host=$HOST zone=$ZONE authoritative=$NS"

IP=""
for _ in $(seq 1 60); do # new ALB + ExternalDNS sync: allow up to 10 minutes
  IP=$(dig +short "$HOST" "@$NS" | grep -E '^[0-9.]+$' | head -1 || true)
  [ -n "$IP" ] && break
  sleep 10
done
[ -n "$IP" ] || { echo "::error::$HOST never got a DNS record"; exit 1; }
RESOLVE=(--resolve "$HOST:443:$IP")

BODY=""
for _ in $(seq 1 30); do # load balancer still provisioning / targets registering
  BODY=$(curl -fsS --max-time 5 "${RESOLVE[@]}" "$URL/") && break
  sleep 10
done
[ -n "$BODY" ] || { echo "::error::$URL never answered"; exit 1; }
echo "$BODY"

if [ -n "$EXPECTED" ] && ! grep -q "\"version\":\"$EXPECTED\"" <<< "$BODY"; then
  echo "::error::live version is not $EXPECTED - the deployment was rolled back"
  exit 1
fi

CODE=$(curl -sS -o readyz.json -w '%{http_code}' --max-time 10 "${RESOLVE[@]}" "$URL/readyz")
cat readyz.json; echo
if grep -q 'not configured' readyz.json; then
  echo "::notice::database disabled - readiness not checked"
elif [ "$CODE" != "200" ]; then
  echo "::error::/readyz returned $CODE"
  exit 1
fi

{
  echo "### Smoke test passed: $URL"
  echo "- version: \`${EXPECTED:-n/a}\`"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
