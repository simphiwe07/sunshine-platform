#!/usr/bin/env bash
# Post-deploy smoke test: smoke.sh <url> [expected-git-sha] [checks: auth,waf]
#  1. wait until the hostname resolves - asking Route 53's authoritative servers,
#     so a too-early lookup can't leave a cached NXDOMAIN on the runner
#  2. HTTPS answers and reports the expected version (else the rollout rolled back)
#  3. /readyz proves the database path (skipped when the DB is disabled)
#  4. with "auth": the app itself is NOT reachable without signing in
#  5. with "waf":  an obvious attack probe is blocked (403) before the app
set -euo pipefail

URL="$1"
EXPECTED="${2:-}"
CHECKS=",${3:-},"
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
# Up to 10 min: the load balancer may still be provisioning, and with GitOps the
# new version arrives asynchronously (Argo CD polls Git, then rolls the pods).
for _ in $(seq 1 60); do
  # /healthz: public even when the rest of the app requires sign-in
  BODY=$(curl -fsS --max-time 5 "${RESOLVE[@]}" "$URL/healthz") || BODY=""
  if [ -n "$BODY" ] && { [ -z "$EXPECTED" ] || grep -q "\"version\":\"$EXPECTED\"" <<< "$BODY"; }; then
    break
  fi
  sleep 10
done
[ -n "$BODY" ] || { echo "::error::$URL never answered"; exit 1; }
echo "$BODY"

if [ -n "$EXPECTED" ] && ! grep -q "\"version\":\"$EXPECTED\"" <<< "$BODY"; then
  echo "::error::live version is not $EXPECTED after 10 min - sync failed or the rollout was stuck (check Argo CD)"
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

if [[ "$CHECKS" == *,auth,* ]]; then
  # Expect the ALB to send an anonymous request to the Cognito sign-in page.
  LOCATION=$(curl -sS -o /dev/null -w '%{redirect_url}' --max-time 10 "${RESOLVE[@]}" "$URL/")
  echo "anonymous GET / -> ${LOCATION:-no redirect}"
  if [[ "$LOCATION" != https://*.amazoncognito.com/oauth2/authorize* ]]; then
    echo "::error::$URL/ is reachable without signing in"
    exit 1
  fi
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${RESOLVE[@]}" "$URL/metrics")
  [ "$CODE" = "404" ] || { echo "::error::/metrics is exposed through the ALB ($CODE)"; exit 1; }
fi

if [[ "$CHECKS" == *,waf,* ]]; then
  # Harmless XSS-looking query on a public endpoint: WAF must answer, not the app.
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${RESOLVE[@]}" -G "$URL/healthz" \
    --data-urlencode 'q=<script>alert(1)</script>')
  echo "XSS probe -> $CODE"
  [ "$CODE" = "403" ] || { echo "::error::WAF did not block the XSS probe ($CODE)"; exit 1; }
fi

{
  echo "### Smoke test passed: $URL"
  echo "- version: \`${EXPECTED:-n/a}\`"
  if [[ "$CHECKS" == *,auth,* ]]; then echo "- sign-in enforced, /metrics blocked"; fi
  if [[ "$CHECKS" == *,waf,* ]]; then echo "- WAF blocks attack probes"; fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
