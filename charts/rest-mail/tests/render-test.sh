#!/usr/bin/env bash
# Renders the umbrella the way a cluster installs it and checks the parts fit:
# that the defaults give the REST API alone, and that it consumes the Secrets
# and TLS the installer is told to provide rather than inventing its own.
set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }
has()  { grep -Fq -- "$3" "$2" || fail "$1 (expected: $3)"; pass "$1"; }
hasnt(){ if grep -Fq -- "$3" "$2"; then fail "$1 (unexpected: $3)"; fi; pass "$1"; }

helm dependency build "$CHART_DIR" > /dev/null
helm lint "$CHART_DIR" --set server.mailserver.hostname=mail.example.com --set server.mailserver.domain=example.com > /dev/null
pass "lints"

# As an installer would: a hostname, an ingress, nothing else.
helm template rest-mail "$CHART_DIR" \
  --set server.mailserver.hostname=mail.example.com \
  --set server.mailserver.domain=example.com \
  --set server.api.ingress.enabled=true \
  --set server.api.ingress.host=mail.example.com \
  --set server.api.ingress.tls.enabled=true \
  --set server.api.ingress.tls.secretName=restmail-tls > "$tmp/out.yaml"

echo "== API only by default =="
has   "API deployed"            "$tmp/out.yaml" 'ghcr.io/rest-mail/api:0.4.0'
has   "Postgres deployed"       "$tmp/out.yaml" 'kind: StatefulSet'
hasnt "no LoadBalancer"         "$tmp/out.yaml" 'type: LoadBalancer'
hasnt "no SMTP gateway"         "$tmp/out.yaml" "name: rest-mail-server-smtp-gateway"

hasnt "no website by default"   "$tmp/out.yaml" "ghcr.io/rest-mail/website"

echo "== consumes what the installer provides =="
hasnt "no generated API Secret" "$tmp/out.yaml" 'JWT_SECRET:'
has   "reads restmail-api"      "$tmp/out.yaml" 'name: restmail-api'
has   "reads restmail-postgres" "$tmp/out.yaml" 'name: restmail-postgres'
has   "mounts restmail-tls"     "$tmp/out.yaml" 'secretName: restmail-tls'
has   "ingress for the host"    "$tmp/out.yaml" 'host: "mail.example.com"'

echo "== the website, where it is asked for =="
helm template rest-mail "$CHART_DIR" \
  --set server.mailserver.hostname=mail.example.com \
  --set server.mailserver.domain=example.com \
  --set website.enabled=true \
  --set website.image.tag=2026.10.10 \
  --set website.ingress.enabled=true \
  --set 'website.ingress.hosts={example.com,www.example.com}' \
  --set website.ingress.tls.enabled=true \
  --set website.ingress.tls.secretName=website-tls > "$tmp/site.yaml"
has "the site deployed"  "$tmp/site.yaml" 'ghcr.io/rest-mail/website:2026.10.10'
has "the apex"           "$tmp/site.yaml" 'host: "example.com"'
has "its certificate"    "$tmp/site.yaml" 'secretName: website-tls'
# The mail server is still the thing this chart is for.
has "the API as well"    "$tmp/site.yaml" 'ghcr.io/rest-mail/api:0.4.0'

echo
echo "All umbrella render tests passed."
