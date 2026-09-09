#!/usr/bin/env bash
# Test runner for vpn. Runs the real script against test/stub/aws-vpn-client.
# Usage: bash test/run.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
export PATH="$here/stub:$PATH"
export VPN_CONNECT_TIMEOUT=2 VPN_POLL_INTERVAL=0.05 NO_COLOR=1
export VPN_NOW=1788937954   # 754 s after the fixture timestamp 2026-09-09T09:00:00+02:00

pass=0
fail=0
out=""
rc=0

setup() {
  VPN_STUB_DIR=$(mktemp -d)
  export VPN_STUB_DIR
  # Deliberately scrambled order; import order is dev, stage, prod, prod-us.
  cat > "$VPN_STUB_DIR/profiles.json" <<'EOF'
[
  {"profile-name": "stage",   "owned-by": "t", "auth-type": "saml", "imported-at": "2026-09-09T09:00:02+02:00"},
  {"profile-name": "dev",     "owned-by": "t", "auth-type": "saml", "imported-at": "2026-09-09T09:00:01+02:00"},
  {"profile-name": "prod-us", "owned-by": "t", "auth-type": "saml", "imported-at": "2026-09-09T09:00:04+02:00"},
  {"profile-name": "prod",    "owned-by": "t", "auth-type": "saml", "imported-at": "2026-09-09T09:00:03+02:00"}
]
EOF
  echo '[]' > "$VPN_STUB_DIR/connections.json"
  : > "$VPN_STUB_DIR/calls.log"
  local p
  for p in dev stage prod; do
    printf 'client\nremote cvpn-endpoint-0123.prod.clientvpn.eu-central-1.amazonaws.com 443\n' > "$VPN_STUB_DIR/config-$p"
  done
  printf 'client\nremote cvpn-endpoint-0456.prod.clientvpn.us-east-2.amazonaws.com 443\n' > "$VPN_STUB_DIR/config-prod-us"
}

connected() {  # mark slugs as connected in the stub
  local p
  for p in "$@"; do
    jq --arg p "$p" '. + [{"profile-name": $p, "initiated-by": "t", "connection-status": "Connected", "last-updated-at": "2026-09-09T09:00:00+02:00"}]' \
      "$VPN_STUB_DIR/connections.json" > "$VPN_STUB_DIR/c.tmp"
    mv "$VPN_STUB_DIR/c.tmp" "$VPN_STUB_DIR/connections.json"
  done
}

run_vpn() {  # runs vpn, captures combined output in $out and exit code in $rc
  out=$("$root/vpn" "$@" 2>&1)
  rc=$?
}

calls() {  # invocations of a stub subcommand, e.g. `calls connect` -> "connect --profile-name dev"
  grep "^$1 " "$VPN_STUB_DIR/calls.log" || true
}

assert_eq() {  # actual expected label
  if [[ "$1" == "$2" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$3" "$2" "$1"
  fi
}

assert_contains() {  # haystack needle label
  if [[ "$1" == *"$2"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected to contain: %q\n  actual: %q\n' "$3" "$2" "$1"
  fi
}

test_case() {  # label function
  echo "- $1"
  setup
  "$2"
  rm -rf "$VPN_STUB_DIR"
}

# --- cases -------------------------------------------------------------------

t_version() {
  run_vpn --version
  assert_eq "$rc" 0 "version exit code"
  assert_eq "$out" "aws-vpn 0.1.0" "version output"
}

t_help() {
  run_vpn --help
  assert_eq "$rc" 0 "help exit code"
  assert_contains "$out" "Usage: vpn" "help mentions usage"
  assert_contains "$out" "prompt" "help lists prompt"
}

t_list_order() {
  connected stage
  run_vpn list
  assert_eq "$rc" 0 "list exit code"
  assert_eq "$out" $'○ dev\n● stage\n○ prod\n○ prod-us' "list follows imported-at order with markers"
}

t_unknown_slug() {
  run_vpn nope
  assert_eq "$rc" 1 "unknown slug exit code"
  assert_contains "$out" "Unknown profile 'nope'" "unknown slug message"
  assert_contains "$out" "dev stage prod prod-us" "unknown slug lists valid ones"
}

t_daemon_down() {
  touch "$VPN_STUB_DIR/fail"
  run_vpn list
  assert_eq "$rc" 1 "daemon down exit code"
  assert_contains "$out" "AWS VPN Client daemon not reachable: systemctl status aws-client-vpn-daemon" "daemon down hint"
}

t_cli_error_json() {
  echo "Maximum number of connections reached" > "$VPN_STUB_DIR/error-connect"
  run_vpn dev
  assert_eq "$rc" 1 "CLI error exit code"
  assert_contains "$out" "✗ Maximum number of connections reached" "CLI error message shown verbatim"
}

test_case "prints version" t_version
test_case "prints help" t_help
test_case "list follows import order" t_list_order
test_case "rejects unknown slug" t_unknown_slug
test_case "reports daemon down" t_daemon_down
test_case "maps CLI error JSON" t_cli_error_json

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
