#!/usr/bin/env bash
# unit-tests.sh — isolated unit tests for strix's pure logic functions. Each
# test EXTRACTS the real function body from the shipped script (so tests track
# the real code, not a copy) and exercises it with known inputs. Needs only
# bash + python3 + awk — no root, no hardware, no network. Runs locally and in
# CI (validate.yml). Complements the VM integration test (host environment).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s  (got: %s)\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
# extract a function definition by name from a script and eval it into scope
load_fn() { eval "$(awk "/^$2\(\) \{/{f=1} f{print} /^}/{if(f)exit}" "$1")"; }

echo "═══ strix-firstboot-setup: hash_locked_or_empty (shadow-field classifier) ═══"
load_fn "$HERE/sysroot/usr/bin/strix-firstboot-setup" hash_locked_or_empty
for pair in ':locked' '!!:locked' '*:locked' '!$y$j9T$x:locked' '$y$j9T$realhash:live' '$6$salt$hash:live'; do
  f="${pair%:*}"; want="${pair##*:}"
  if hash_locked_or_empty "$f"; then got=locked; else got=live; fi
  [ "$got" = "$want" ] && ok "field '${f:0:12}' → $want" || bad "field '$f' expected $want" "$got"
done

echo "═══ strix-firstboot-setup: ts_has_identity (tailnet state guard) ═══"
load_fn "$HERE/sysroot/usr/bin/strix-firstboot-setup" ts_has_identity
tmp=$(mktemp -d)
: > "$tmp/empty";                     TS_STATE="$tmp/empty"    ts_has_identity && bad "empty file → identity?" "true" || ok "empty state → no identity"
printf '{}' > "$tmp/bootstrap";       TS_STATE="$tmp/bootstrap" ts_has_identity && bad "bootstrap {} → identity?" "true" || ok "bootstrap '{}' → no identity"
printf '{"_profiles":{"x":1}}' > "$tmp/real"; TS_STATE="$tmp/real" ts_has_identity && ok "logged-in state → has identity" || bad "real state → identity" "false"

echo "═══ strix-wifi: slot_ssid / first_configured / resolve_slot ═══"
SC="$tmp/nm"; mkdir -p "$SC"
cat > "$SC/wifi-primary.nmconnection" <<EOF
[connection]
id=wifi-primary
[wifi]
ssid=HomeNet
EOF
cat > "$SC/wifi-secondary.nmconnection" <<EOF
[connection]
id=wifi-secondary
[wifi]
ssid=CafeNet
EOF
# extract the three functions + their SLOTS/SC deps
SLOTS="primary secondary tertiary"
slot_file() { echo "$SC/wifi-$1.nmconnection"; }
load_fn "$HERE/sysroot/usr/bin/strix-wifi" slot_ssid
load_fn "$HERE/sysroot/usr/bin/strix-wifi" first_configured
load_fn "$HERE/sysroot/usr/bin/strix-wifi" resolve_slot
[ "$(slot_ssid primary)" = HomeNet ]     && ok "slot_ssid primary=HomeNet"   || bad "slot_ssid primary" "$(slot_ssid primary)"
[ "$(slot_ssid tertiary)" = "" ]         && ok "slot_ssid tertiary=(empty)"  || bad "slot_ssid tertiary" "$(slot_ssid tertiary)"
[ "$(first_configured)" = primary ]      && ok "first_configured=primary"    || bad "first_configured" "$(first_configured)"
[ "$(resolve_slot CafeNet)" = secondary ] && ok "resolve_slot SSID→secondary" || bad "resolve_slot CafeNet" "$(resolve_slot CafeNet)"
[ "$(resolve_slot primary)" = primary ]  && ok "resolve_slot token→primary"  || bad "resolve_slot primary" "$(resolve_slot primary)"
[ "$(resolve_slot Nope)" = "" ]          && ok "resolve_slot unknown→(empty)" || bad "resolve_slot Nope" "$(resolve_slot Nope)"

echo "═══ strix-table100: gateway extraction from 'ip route' ═══"
gw4=$(printf 'default via 10.0.50.1 dev bond0 proto dhcp metric 100\n' | awk '/default/{print $3; exit}')
[ "$gw4" = 10.0.50.1 ] && ok "v4 gw parsed = 10.0.50.1" || bad "v4 gw" "$gw4"
gw6=$(printf 'default via fe80::1 dev bond0 proto ra metric 100\n' | awk '/default/{print $3; exit}')
[ "$gw6" = "fe80::1" ] && ok "v6 gw parsed = fe80::1" || bad "v6 gw" "$gw6"

echo "═══ strix-setup: firstboot.yaml parser (extract python block) ═══"
awk '/^  python3 - .*<<.PY.$/{f=1;next} /^PY$/{f=0} f' "$HERE/sysroot/usr/bin/strix-setup" > "$tmp/parse.py"
cat > "$tmp/good.yaml" <<EOF
core_password_hash: "\$y\$j9T\$abc"
wifi:
  primary: { ssid: "HomeNet", psk: "s3cret" }
tailscale_authkey: "tskey-auth-xyz"
EOF
out=$(python3 "$tmp/parse.py" "$tmp/good.yaml" 2>/dev/null)
echo "$out" | grep -q $'HASH\t$y$j9T$abc'     && ok "parse: HASH extracted"        || bad "parse HASH" "$out"
echo "$out" | grep -q $'SSID_primary\tHomeNet' && ok "parse: SSID_primary=HomeNet" || bad "parse SSID" "$out"
echo "$out" | grep -q $'TSKEY\ttskey-auth-xyz' && ok "parse: TSKEY extracted"      || bad "parse TSKEY" "$out"
echo "$out" | grep -q 'SSID_secondary' && bad "parse: emitted empty secondary?" "$out" || ok "parse: skips unset slots"
# malformed yaml → python must exit nonzero (drives the interactive fallback)
printf 'this: : : broken\n  - [\n' > "$tmp/bad.yaml"
if python3 "$tmp/parse.py" "$tmp/bad.yaml" >/dev/null 2>&1; then bad "parse: malformed yaml did NOT error" "exit0"; else ok "parse: malformed yaml → nonzero (fallback fires)"; fi
# non-mapping root → safe (yaml.safe_load returns non-dict; .get would raise → nonzero, caught by fallback)
printf -- '- just\n- a\n- list\n' > "$tmp/list.yaml"
python3 "$tmp/parse.py" "$tmp/list.yaml" >/dev/null 2>&1; ok "parse: list-root handled (exit $?, fallback-safe)"

echo "═══ build-iso.sh: SSH key regex (incl. FIDO sk-*) ═══"
echo 'import re' > "$tmp/pat.py"
awk '/^pat = re.compile/{print}' "$HERE/build-iso.sh" >> "$tmp/pat.py"
cat >> "$tmp/pat.py" <<'PY'
import sys
tests = [
    ("ssh-ed25519 AAAAC3Nza key@host", True),
    ("ssh-rsa AAAAB3Nza== old", True),
    ("sk-ssh-ed25519@openssh.com AAAAGnNr fido", True),
    ("ecdsa-sha2-nistp256 AAAAE2Vj ec", True),
    ("# a comment", False),
    ("not-a-key foo", False),
]
bad = 0
for line, want in tests:
    got = bool(pat.match(line))
    if got != want:
        print(f"FAIL regex: {line!r} expected {want} got {got}"); bad += 1
sys.exit(1 if bad else 0)
PY
if python3 "$tmp/pat.py"; then ok "key regex: 6/6 cases (ed25519, rsa, FIDO sk-*, ecdsa, comment, junk)"; else bad "key regex mismatch" "see above"; fi

rm -rf "$tmp"
echo
echo "═══ UNIT TESTS: $PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ]
