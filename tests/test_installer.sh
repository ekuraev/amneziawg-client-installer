#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2034,SC2012,SC2002
# (подмены curl и переменные вроде CONF_DIR_OVERRIDE читаются внутри sourced-скрипта)
# Тесты чистых функций install-awg-client.sh (без сети и root).
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install-awg-client.sh"
FAILS=0; PASSES=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASSES=$((PASSES+1)); else FAILS=$((FAILS+1)); echo "FAIL $3: ожидалось '$1', получено '$2'"; fi; }
assert_fail() { if "$@" >/dev/null 2>&1; then FAILS=$((FAILS+1)); echo "FAIL: '$*' должно было упасть"; else PASSES=$((PASSES+1)); fi; }
mk_conf() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }
TMPT="$(mktemp -d)"; trap 'rm -rf "$TMPT"' EXIT

# shellcheck source=/dev/null
source "$SCRIPT"
set +e  # скрипт включает set -e; для тестов отключаем

# --- Task 1: parse_args ---
test_parse_args_defaults() {
  parse_args /tmp/x.conf
  assert_eq "/tmp/x.conf" "$CONF_SRC" "conf path"
  assert_eq "awg0" "$IFACE" "iface default"
  assert_eq 0 "$USERSPACE" "userspace default"
  assert_eq 0 "$NO_START" "no-start default"
}
test_parse_args_flags() {
  parse_args --iface vpn1 --userspace --no-start /tmp/y.conf
  assert_eq "vpn1" "$IFACE" "iface flag"
  assert_eq 1 "$USERSPACE" "userspace flag"
  assert_eq 1 "$NO_START" "no-start flag"
}
test_parse_args_bad_iface() { assert_fail bash -c "source '$SCRIPT'; parse_args --iface 'bad name!' /tmp/z.conf"; }
test_parse_args_no_conf()   { assert_fail bash -c "source '$SCRIPT'; parse_args --userspace"; }
test_version_flag()         { assert_eq "install-awg-client.sh dev" "$(bash "$SCRIPT" --version)" "version flag"; }
test_pipe_mode()            { assert_eq "install-awg-client.sh dev" "$(cat "$SCRIPT" | bash -s -- --version)" "curl | bash mode"; }

# --- Task 2: validate_config ---
test_validate_config() {
  mk_conf "$TMPT/good.conf" "[Interface]" "PrivateKey = abc" "Address = 10.0.0.2/32" "DNS = 1.1.1.1" "Jc = 4" "[Peer]" "PublicKey = def" "Endpoint = 1.2.3.4:51820" "AllowedIPs = 0.0.0.0/0, ::/0"
  mk_conf "$TMPT/nopeer.conf" "[Interface]" "PrivateKey = abc"
  mk_conf "$TMPT/split.conf" "[Interface]" "PrivateKey = abc" "[Peer]" "Endpoint = h:1" "AllowedIPs = 10.0.0.0/24"
  validate_config "$TMPT/good.conf"; assert_eq 0 $? "good conf validates"
  assert_fail bash -c "source '$SCRIPT'; validate_config '$TMPT/nopeer.conf'"
  assert_fail bash -c "source '$SCRIPT'; validate_config '$TMPT/missing.conf'"
  config_has_dns "$TMPT/good.conf"; assert_eq 0 $? "has dns"
  config_has_dns "$TMPT/split.conf"; assert_eq 1 $? "no dns"
  config_is_full_tunnel "$TMPT/good.conf"; assert_eq 0 $? "full tunnel"
  config_is_full_tunnel "$TMPT/split.conf"; assert_eq 1 $? "split tunnel"
}

# --- Task 3: resolve_versions ---
test_resolve_versions_offline() {
  curl() { return 7; }
  unset AWG_KMOD_TAG AWG_TOOLS_TAG AWG_GO_TAG AWG_GOLANG_VERSION
  resolve_versions 2>/dev/null
  assert_eq "v3.1.20260828" "$KMOD_TAG" "kmod fallback"
  assert_eq "v3.1.20260812" "$TOOLS_TAG" "tools fallback"
  assert_eq "go1.27.1" "$GOLANG_VERSION" "golang fallback"
  unset -f curl
}
test_resolve_versions_online() {
  curl() { case "$*" in *tags*) echo '[{"name":"v9.9.20990101","zipball_url":"x"}]';; *go.dev*) echo '[{"version":"go1.99.0","stable":true}]';; esac; }
  unset AWG_KMOD_TAG AWG_TOOLS_TAG AWG_GO_TAG AWG_GOLANG_VERSION
  resolve_versions
  assert_eq "v9.9.20990101" "$KMOD_TAG" "kmod online"
  assert_eq "go1.99.0" "$GOLANG_VERSION" "golang online"
  unset -f curl
}
test_resolve_versions_env() {
  curl() { echo '[{"name":"v9.9.20990101"}]'; }
  AWG_KMOD_TAG="v1.0.20260618" resolve_versions
  assert_eq "v1.0.20260618" "$KMOD_TAG" "kmod env override"
  unset -f curl
}

# --- Task 4: header_candidates ---
test_header_candidates() {
  local out
  out="$(header_candidates '6.12.25+rpt-rpi-2712' debian arm64 | tr '\n' ' ')"
  assert_eq "linux-headers-6.12.25+rpt-rpi-2712 linux-headers-rpi-2712 raspberrypi-kernel-headers linux-headers-arm64 " "$out" "pi5"
  out="$(header_candidates '6.6.31+rpt-rpi-v8' debian arm64 | tr '\n' ' ')"
  assert_eq "linux-headers-6.6.31+rpt-rpi-v8 linux-headers-rpi-v8 raspberrypi-kernel-headers linux-headers-arm64 " "$out" "pi4 arm64"
  out="$(header_candidates '6.6.31+rpt-rpi-v7l' debian armhf | tr '\n' ' ')"
  assert_eq "linux-headers-6.6.31+rpt-rpi-v7l linux-headers-rpi-v7l raspberrypi-kernel-headers linux-headers-armhf " "$out" "pi armhf v7l"
  out="$(header_candidates '6.8.0-1010-raspi' ubuntu arm64 | tr '\n' ' ')"
  assert_eq "linux-headers-6.8.0-1010-raspi linux-headers-raspi linux-headers-generic " "$out" "ubuntu raspi"
  out="$(header_candidates '6.1.21-v8+' debian arm64 | tr '\n' ' ')"
  assert_eq "linux-headers-6.1.21-v8+ raspberrypi-kernel-headers linux-headers-arm64 " "$out" "bullseye legacy v8+"
  out="$(header_candidates '5.15.84-v7l+' raspbian armhf | tr '\n' ' ')"
  assert_eq "linux-headers-5.15.84-v7l+ raspberrypi-kernel-headers linux-headers-armhf " "$out" "bullseye legacy v7l+"
  out="$(header_candidates '6.1.0-21-amd64' debian amd64 | tr '\n' ' ')"
  assert_eq "linux-headers-6.1.0-21-amd64 linux-headers-amd64 " "$out" "debian amd64"
}

# --- Task 6: install_config, confirm_ssh_risk ---
test_install_config() {
  local d="$TMPT/etc"; CONF_DIR_OVERRIDE="$d"
  mk_conf "$TMPT/c1.conf" "[Interface]" "PrivateKey = a" "[Peer]" "Endpoint = h:1" "AllowedIPs = 10.0.0.0/24"
  local dst; dst="$(install_config "$TMPT/c1.conf" awg0 2>/dev/null)"
  assert_eq "$d/awg0.conf" "$dst" "dst path"
  assert_eq "600" "$(stat -f %Lp "$dst" 2>/dev/null || stat -c %a "$dst")" "mode 600"
  mk_conf "$TMPT/c2.conf" "[Interface]" "PrivateKey = b" "[Peer]" "Endpoint = h:1" "AllowedIPs = 10.0.0.0/24"
  install_config "$TMPT/c2.conf" awg0 >/dev/null 2>&1
  assert_eq 1 "$(ls "$d"/awg0.conf.bak.* | wc -l | tr -d ' ')" "backup created"
  unset CONF_DIR_OVERRIDE
}
test_confirm_ssh_risk() {
  mk_conf "$TMPT/full.conf" "[Interface]" "PrivateKey = a" "[Peer]" "Endpoint = h:1" "AllowedIPs = 0.0.0.0/0"
  mk_conf "$TMPT/spl.conf"  "[Interface]" "PrivateKey = a" "[Peer]" "Endpoint = h:1" "AllowedIPs = 10.0.0.0/24"
  ( unset SSH_CONNECTION; confirm_ssh_risk "$TMPT/full.conf" ); assert_eq 0 $? "no ssh -> ok"
  ( SSH_CONNECTION="1 2 3 4"; confirm_ssh_risk "$TMPT/spl.conf" ); assert_eq 0 $? "ssh split -> ok"
  ( SSH_CONNECTION="1 2 3 4"; AWG_TTY="$TMPT/no-such-tty"; confirm_ssh_risk "$TMPT/full.conf" 2>/dev/null ); assert_eq 1 $? "ssh full no tty -> refuse"
  echo n > "$TMPT/tty-n"; echo y > "$TMPT/tty-y"
  ( SSH_CONNECTION="1 2 3 4"; AWG_TTY="$TMPT/tty-n"; confirm_ssh_risk "$TMPT/full.conf" 2>/dev/null ); assert_eq 1 $? "ssh full answer n -> refuse"
  ( SSH_CONNECTION="1 2 3 4"; AWG_TTY="$TMPT/tty-y"; confirm_ssh_risk "$TMPT/full.conf" 2>/dev/null ); assert_eq 0 $? "ssh full answer y -> ok"
  # stdin не должен использоваться (при curl | bash там лежит сам скрипт)
  ( SSH_CONNECTION="1 2 3 4"; AWG_TTY="$TMPT/tty-n"; echo y | confirm_ssh_risk "$TMPT/full.conf" 2>/dev/null ); assert_eq 1 $? "stdin ignored"
}

test_parse_args_defaults; test_parse_args_flags; test_parse_args_bad_iface; test_parse_args_no_conf; test_version_flag; test_pipe_mode
test_validate_config
test_resolve_versions_offline; test_resolve_versions_online; test_resolve_versions_env
test_header_candidates
test_install_config; test_confirm_ssh_risk
echo "PASS=$PASSES FAIL=$FAILS"; [[ $FAILS -eq 0 ]]
