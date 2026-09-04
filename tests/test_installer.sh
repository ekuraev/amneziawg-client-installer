#!/usr/bin/env bash
# shellcheck disable=SC2329,SC2317,SC2034,SC2012,SC2002
# (подмены curl и переменные вроде CONF_DIR_OVERRIDE читаются внутри sourced-скрипта)
# Тесты чистых функций install-awg-client.sh (без сети и root).
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install-awg-client.sh"
FAILS=0; PASSES=0
assert_eq() { if [[ "$1" == "$2" ]]; then PASSES=$((PASSES+1)); else FAILS=$((FAILS+1)); echo "FAIL $3: ожидалось '$1', получено '$2'"; fi; }
assert_fail() { if "$@" >/dev/null 2>&1; then FAILS=$((FAILS+1)); echo "FAIL: '$*' должно было упасть"; else PASSES=$((PASSES+1)); fi; }
mk_conf() { local f="$1"; shift; printf '%s\n' "$@" > "$f"; }
# Права файла в восьмеричном виде: GNU stat (Linux) и BSD stat (macOS) различаются
file_mode() { if stat --version >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi; }
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
  assert_eq "600" "$(file_mode "$dst")" "mode 600"
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

# --- exclude-lan ---
test_parse_exclude_lan() {
  parse_args --exclude-lan /tmp/x.conf
  assert_eq 1 "$EXCLUDE_LAN" "exclude-lan auto flag"
  assert_eq "" "$EXCLUDE_LAN_LIST" "exclude-lan auto list empty"
  parse_args --exclude-lan=192.168.0.0/16,10.0.0.0/24 /tmp/x.conf
  assert_eq 1 "$EXCLUDE_LAN" "exclude-lan explicit flag"
  assert_eq "192.168.0.0/16,10.0.0.0/24" "$EXCLUDE_LAN_LIST" "exclude-lan explicit list"
  parse_args /tmp/x.conf
  assert_eq 0 "$EXCLUDE_LAN" "exclude-lan default off"
}
test_validate_cidr4() {
  validate_cidr4 192.168.1.0/24; assert_eq 0 $? "cidr ok"
  validate_cidr4 10.0.0.0/8;     assert_eq 0 $? "cidr /8 ok"
  validate_cidr4 192.168.1.0;    assert_eq 1 $? "cidr no prefix"
  validate_cidr4 192.168.1.0/33; assert_eq 1 $? "cidr prefix > 32"
  validate_cidr4 192.168.300.0/24; assert_eq 1 $? "cidr octet > 255"
  validate_cidr4 "fd00::/64";    assert_eq 1 $? "cidr ipv6 rejected"
}
test_ip_in_cidr() {
  ip_in_cidr 192.168.1.5 192.168.1.0/24; assert_eq 0 $? "ip in /24"
  ip_in_cidr 192.168.2.5 192.168.1.0/24; assert_eq 1 $? "ip not in /24"
  ip_in_cidr 10.200.3.4 10.0.0.0/8;      assert_eq 0 $? "ip in /8"
  ip_in_cidr 8.8.8.8 0.0.0.0/0;          assert_eq 0 $? "ip in /0"
}
test_detect_lan_subnets() {
  ip() { printf '%s\n' \
    '192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10 metric 100' \
    '10.8.0.0/24 dev awg0 proto kernel scope link src 10.8.0.2' \
    '172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown' \
    '192.168.50.0/24 dev wlan0 proto kernel scope link src 192.168.50.7 metric 600'; }
  assert_eq "192.168.1.0/24 192.168.50.0/24 " "$(detect_lan_subnets | tr '\n' ' ')" "detect lan subnets"
  unset -f ip
}
test_resolve_exclude_subnets() {
  EXCLUDE_LAN_LIST="192.168.0.0/16, 10.0.0.0/24"; resolve_exclude_subnets
  assert_eq "192.168.0.0/16 10.0.0.0/24" "${EXCLUDE_SUBNETS[*]}" "explicit subnets parsed"
  assert_fail bash -c "source '$SCRIPT'; EXCLUDE_LAN_LIST='192.168.1.0/99'; resolve_exclude_subnets"
  ip() { :; }
  assert_fail bash -c "source '$SCRIPT'; ip() { :; }; EXCLUDE_LAN_LIST=''; resolve_exclude_subnets"
  unset -f ip; EXCLUDE_LAN_LIST=""
}
test_apply_exclude_lan() {
  mk_conf "$TMPT/src.conf" "[Interface]" "PrivateKey = a" "Address = 10.8.0.2/32" "[Peer]" "PublicKey = b" "Endpoint = h:1" "AllowedIPs = 0.0.0.0/0"
  apply_exclude_lan "$TMPT/src.conf" "$TMPT/out1.conf" 192.168.1.0/24 192.168.50.0/24
  assert_eq 2 "$(grep -c '^PostUp = ip -4 rule add to ' "$TMPT/out1.conf")" "two PostUp"
  assert_eq 2 "$(grep -c '^PreDown = ip -4 rule del to ' "$TMPT/out1.conf")" "two PreDown"
  assert_eq "[Interface]" "$(sed -n 1p "$TMPT/out1.conf")" "interface first"
  assert_eq "$EXCLUDE_MARK_BEGIN" "$(sed -n 2p "$TMPT/out1.conf")" "block right after [Interface]"
  grep -q 'PostUp = ip -4 rule add to 192.168.1.0/24 lookup main priority 100$' "$TMPT/out1.conf"; assert_eq 0 $? "postup line"
  grep -q '^AllowedIPs = 0.0.0.0/0$' "$TMPT/out1.conf"; assert_eq 0 $? "AllowedIPs untouched"
  # идемпотентность: повторная трансформация выхода с другим списком заменяет блок
  apply_exclude_lan "$TMPT/out1.conf" "$TMPT/out2.conf" 10.0.0.0/24
  assert_eq 1 "$(grep -c '^PostUp = ' "$TMPT/out2.conf")" "old block replaced"
  assert_eq 1 "$(grep -c "^$EXCLUDE_MARK_BEGIN\$" "$TMPT/out2.conf")" "single begin marker"
  assert_eq "$(grep -c '' "$TMPT/src.conf")" "$(grep -v -e '^PostUp' -e '^PreDown' -e '^# ' "$TMPT/out2.conf" | grep -c '')" "other lines preserved"
}
test_confirm_ssh_risk_exclude_lan() {
  mk_conf "$TMPT/full2.conf" "[Interface]" "PrivateKey = a" "[Peer]" "Endpoint = h:1" "AllowedIPs = 0.0.0.0/0"
  ( SSH_CONNECTION="192.168.1.20 5555 192.168.1.10 22"; AWG_TTY="$TMPT/no-such-tty"; EXCLUDE_SUBNETS=(192.168.1.0/24); confirm_ssh_risk "$TMPT/full2.conf" 2>/dev/null ); assert_eq 0 $? "ssh client in excluded lan -> no prompt"
  ( SSH_CONNECTION="203.0.113.5 5555 192.168.1.10 22"; AWG_TTY="$TMPT/no-such-tty"; EXCLUDE_SUBNETS=(192.168.1.0/24); confirm_ssh_risk "$TMPT/full2.conf" 2>/dev/null ); assert_eq 1 $? "ssh client outside lan -> prompt/refuse"
}

test_parse_args_defaults; test_parse_args_flags; test_parse_args_bad_iface; test_parse_args_no_conf; test_version_flag; test_pipe_mode
test_validate_config
test_resolve_versions_offline; test_resolve_versions_online; test_resolve_versions_env
test_header_candidates
test_install_config; test_confirm_ssh_risk
test_parse_exclude_lan; test_validate_cidr4; test_ip_in_cidr; test_detect_lan_subnets; test_resolve_exclude_subnets; test_apply_exclude_lan; test_confirm_ssh_risk_exclude_lan
echo "PASS=$PASSES FAIL=$FAILS"; [[ $FAILS -eq 0 ]]
