#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
set -a
source "$project_dir/.env"
set +a

gateway_url="${GATEWAY_TEST_URL:-http://localhost:8080}"
created="$(curl --fail --silent "$gateway_url/v1/pairings" \
  -H 'Content-Type: application/json' \
  -H "X-Admin-Secret: $ADMIN_SETUP_SECRET" \
  -d '{"displayName":"macOS smoke test","platform":"web"}')"
pairing_id="$(printf '%s' "$created" | jq -r '.pairingId')"
pairing_code="$(printf '%s' "$created" | jq -r '.code')"

curl --fail --silent "$gateway_url/v1/pairings/$pairing_id/approve" \
  -H 'Content-Type: application/json' \
  -H "X-Admin-Secret: $ADMIN_SETUP_SECRET" \
  -d '{"friendlyName":"macOS smoke test"}' >/dev/null

claimed="$(curl --fail --silent "$gateway_url/v1/pairings/$pairing_id/claim" \
  -H 'Content-Type: application/json' \
  -d "{\"code\":\"$pairing_code\"}")"
device_id="$(printf '%s' "$claimed" | jq -r '.deviceId')"
access_token="$(printf '%s' "$claimed" | jq -r '.accessToken')"

cleanup() {
  curl --silent -X DELETE "$gateway_url/v1/admin/devices/$device_id" \
    -H "X-Admin-Secret: $ADMIN_SETUP_SECRET" >/dev/null || true
}
trap cleanup EXIT

realtime="$(curl --fail --silent -X POST "$gateway_url/v1/realtime/token" \
  -H "Authorization: Bearer $access_token")"
printf '%s' "$realtime" | jq -e '{url, room, tokenPresent: (.token | length > 0)}'
