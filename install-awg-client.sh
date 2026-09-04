#!/usr/bin/env bash
# install-awg-client.sh — установка клиента AmneziaWG на Debian, Ubuntu, Raspberry Pi OS
# и другие apt-системы с systemd (x86_64, arm64, armhf).
#
# Ставит модуль ядра amneziawg через DKMS (fallback: userspace amneziawg-go),
# собирает amneziawg-tools, кладёт готовый клиентский конфиг в
# /etc/amnezia/amneziawg/<iface>.conf и включает автозапуск awg-quick@<iface>.
#
# Использование: sudo ./install-awg-client.sh <client.conf> [--iface NAME] [--userspace] [--no-start]
# Одной командой:
#   curl -fsSL https://github.com/ekuraev/amneziawg-client-installer/releases/latest/download/install-awg-client.sh \
#     | sudo bash -s -- ~/client.conf
set -euo pipefail

# Подставляется при сборке релиза (см. .github/workflows/release.yml)
readonly SCRIPT_VERSION="dev"

readonly DEFAULT_KMOD_TAG="v3.1.20260828"
readonly DEFAULT_TOOLS_TAG="v3.1.20260812"
readonly DEFAULT_GO_TAG="v3.1.20260828"
readonly DEFAULT_GOLANG_VERSION="go1.27.1"
readonly CONF_DIR="/etc/amnezia/amneziawg"
readonly LOG_FILE="/var/log/awg-client-install.log"
readonly DKMS_NAME="amneziawg"
readonly DKMS_VER="1.0.0"

CONF_SRC=""; IFACE="awg0"; USERSPACE=0; NO_START=0
EXCLUDE_LAN=0; EXCLUDE_LAN_LIST=""; EXCLUDE_SUBNETS=()
CONFIG_ONLY=0; REINSTALL=0; NO_EXCLUDE_LAN=0; MODE=""
DST_CONF=""; CONFIG_CHANGED=0
readonly EXCLUDE_MARK_BEGIN="# >>> amneziawg-client-installer exclude-lan >>>"
readonly EXCLUDE_MARK_END="# <<< amneziawg-client-installer exclude-lan <<<"
WORK_DIR=""
ARCH=""; OS_ID=""; _APT_UPDATED=0
KMOD_TAG=""; TOOLS_TAG=""; GO_TAG=""; GOLANG_VERSION=""
IMPL=""

# ---------------------------------------------------------------- вывод

log_info() { echo -e "\e[36m[i]\e[0m $*"; }
log_ok()   { echo -e "\e[32m[+]\e[0m $*"; }
log_warn() { echo -e "\e[33m[!]\e[0m $*" >&2; }
log_err()  { echo -e "\e[31m[x]\e[0m $*" >&2; }
die()      { log_err "$*"; exit 1; }

# ask_yes_no <вопрос> <y|n по умолчанию>: читает ответ с терминала (не со stdin,
# при curl | bash там лежит сам скрипт). Без терминала берётся значение по умолчанию.
ask_yes_no() {
  local prompt="$1" default="$2" ans="" tty="${AWG_TTY:-/dev/tty}" hint="[y/N]"
  [[ "$default" == y ]] && hint="[Y/n]"
  log_warn "$prompt $hint"
  if [[ -r "$tty" ]]; then
    read -r ans < "$tty" || true
  else
    log_warn "Нет терминала для ответа, принимаю вариант по умолчанию: $default"
  fi
  [[ -z "$ans" ]] && ans="$default"
  [[ "$ans" =~ ^[yYдД] ]]
}

usage() {
  cat <<EOF
Использование: sudo $0 <client.conf> [--iface NAME] [--exclude-lan[=CIDR,...]] [--config-only|--reinstall] [--userspace] [--no-start]

  <client.conf>   клиентский конфиг AmneziaWG (формат awg-quick)
  --iface NAME    имя интерфейса (по умолчанию awg0)
  --exclude-lan   не пускать в туннель локальные IPv4-подсети, к которым машина
                  подключена напрямую (она остаётся доступной в своей сети)
  --exclude-lan=192.168.0.0/16,10.0.0.0/24
                  то же, но со своим списком подсетей
  --no-exclude-lan убрать исключение локальной сети из установленного конфига
  --config-only   компоненты уже установлены: только обновить конфиг и перезапустить
  --reinstall     полная переустановка без вопросов (обновляет модуль и tools)
  --userspace     не собирать модуль ядра, сразу ставить amneziawg-go
  --no-start      установить, но не поднимать туннель
  --version       версия скрипта
  -h, --help      эта справка

Переменные окружения для фиксации версий:
  AWG_KMOD_TAG      тег amneziawg-linux-kernel-module (по умолчанию: последний с GitHub)
  AWG_TOOLS_TAG     тег amneziawg-tools
  AWG_GO_TAG        тег amneziawg-go
  AWG_GOLANG_VERSION версия Go toolchain для сборки amneziawg-go (например go1.27.1)
EOF
}

# ---------------------------------------------------------------- аргументы

parse_args() {
  CONF_SRC=""; IFACE="awg0"; USERSPACE=0; NO_START=0; EXCLUDE_LAN=0; EXCLUDE_LAN_LIST=""
  CONFIG_ONLY=0; REINSTALL=0; NO_EXCLUDE_LAN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iface) [[ $# -ge 2 ]] || die "--iface требует значение"; IFACE="$2"; shift 2 ;;
      --exclude-lan) EXCLUDE_LAN=1; EXCLUDE_LAN_LIST=""; shift ;;
      --exclude-lan=*) EXCLUDE_LAN=1; EXCLUDE_LAN_LIST="${1#--exclude-lan=}"; shift ;;
      --no-exclude-lan) NO_EXCLUDE_LAN=1; shift ;;
      --config-only) CONFIG_ONLY=1; shift ;;
      --reinstall) REINSTALL=1; shift ;;
      --userspace) USERSPACE=1; shift ;;
      --no-start) NO_START=1; shift ;;
      --version) echo "install-awg-client.sh $SCRIPT_VERSION"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "Неизвестный аргумент: $1" ;;
      *) [[ -z "$CONF_SRC" ]] || die "Лишний аргумент: $1"; CONF_SRC="$1"; shift ;;
    esac
  done
  [[ -n "$CONF_SRC" ]] || { usage >&2; die "Не указан путь к конфигу"; }
  [[ "$IFACE" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || die "Недопустимое имя интерфейса: $IFACE"
  [[ $CONFIG_ONLY -eq 1 && $REINSTALL -eq 1 ]] && die "--config-only и --reinstall несовместимы"
  [[ $EXCLUDE_LAN -eq 1 && $NO_EXCLUDE_LAN -eq 1 ]] && die "--exclude-lan и --no-exclude-lan несовместимы"
  return 0
}

# ---------------------------------------------------------------- конфиг

_conf_has_key() { grep -Eiq "^[[:space:]]*$2[[:space:]]*=" "$1"; }

validate_config() {
  local f="$1"
  [[ -f "$f" ]] || die "Файл конфига не найден: $f"
  [[ -r "$f" ]] || die "Файл конфига недоступен для чтения: $f"
  grep -Eq '^\[Interface\]' "$f" || die "В конфиге нет секции [Interface]: $f"
  grep -Eq '^\[Peer\]' "$f"      || die "В конфиге нет секции [Peer]: $f"
  _conf_has_key "$f" PrivateKey  || die "В конфиге нет PrivateKey"
  _conf_has_key "$f" Endpoint    || die "В конфиге нет Endpoint"
  _conf_has_key "$f" AllowedIPs  || die "В конфиге нет AllowedIPs"
}

config_has_dns() { _conf_has_key "$1" DNS; }

config_is_full_tunnel() {
  grep -Ei '^[[:space:]]*AllowedIPs[[:space:]]*=' "$1" | grep -Eq '(^|[^0-9])0\.0\.0\.0/0|::/0'
}

# ---------------------------------------------------------------- исключение локальной сети

validate_cidr4() {
  local c="$1" ip pfx o x
  [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  ip="${c%/*}"; pfx="${c#*/}"
  (( 10#$pfx <= 32 )) || return 1
  IFS=. read -r -a o <<< "$ip"
  for x in "${o[@]}"; do (( 10#$x <= 255 )) || return 1; done
}

ip4_to_int() {
  local o
  IFS=. read -r -a o <<< "$1"
  echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# ip_in_cidr <ip> <cidr>: 0, если адрес входит в подсеть
ip_in_cidr() {
  local ip net pfx mask
  ip="$(ip4_to_int "$1")"; net="$(ip4_to_int "${2%/*}")"; pfx="${2#*/}"
  if (( 10#$pfx == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - 10#$pfx)) & 0xFFFFFFFF )); fi
  (( (ip & mask) == (net & mask) ))
}

# Печатает IPv4-подсети физических интерфейсов (без VPN, docker, loopback), по одной на строку.
detect_lan_subnets() {
  ip -4 -o route show scope link proto kernel 2>/dev/null \
    | awk '$1 ~ /\// && $2 == "dev" && $3 !~ /^(lo|awg|wg|docker|br-|veth|virbr|tun|tap)/ { print $1 }' \
    | sort -u
}

# Заполняет EXCLUDE_SUBNETS из EXCLUDE_LAN_LIST или автоопределения.
resolve_exclude_subnets() {
  local c list=()
  EXCLUDE_SUBNETS=()
  if [[ -n "$EXCLUDE_LAN_LIST" ]]; then
    IFS=, read -r -a list <<< "$EXCLUDE_LAN_LIST"
    for c in "${list[@]}"; do
      c="${c// /}"
      [[ -n "$c" ]] || continue
      validate_cidr4 "$c" || die "Некорректная IPv4-подсеть в --exclude-lan: $c (пример: 192.168.1.0/24)"
      EXCLUDE_SUBNETS+=("$c")
    done
  else
    while read -r c; do [[ -n "$c" ]] && EXCLUDE_SUBNETS+=("$c"); done < <(detect_lan_subnets)
  fi
  (( ${#EXCLUDE_SUBNETS[@]} > 0 )) || die "Не удалось определить локальные подсети. Укажите явно: --exclude-lan=192.168.1.0/24"
}

# apply_exclude_lan <src> <dst> <cidr>...: копия конфига с PostUp/PreDown-правилами
# для локальных подсетей после [Interface]. Старый блок между маркерами заменяется.
apply_exclude_lan() {
  local src="$1" dst="$2"; shift 2
  local c line skip=0 done=0
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$EXCLUDE_MARK_BEGIN" ]]; then skip=1; continue; fi
      if [[ "$line" == "$EXCLUDE_MARK_END" ]]; then skip=0; continue; fi
      (( skip )) && continue
      printf '%s\n' "$line"
      if [[ $done -eq 0 && "$line" =~ ^\[Interface\] ]]; then
        printf '%s\n' "$EXCLUDE_MARK_BEGIN"
        for c in "$@"; do
          printf 'PostUp = ip -4 rule add to %s lookup main priority 100\n' "$c"
          printf 'PreDown = ip -4 rule del to %s lookup main priority 100 || true\n' "$c"
        done
        printf '%s\n' "$EXCLUDE_MARK_END"
        done=1
      fi
    done < "$src"
  } > "$dst"
}

# ---------------------------------------------------------------- режим: установка или обновление конфига

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 0, если awg/awg-quick есть и есть хотя бы одна реализация (модуль ядра или amneziawg-go)
is_installed() {
  local sysfs="${AWG_MODULE_SYSFS:-/sys/module/amneziawg}" gobin="${AWG_GO_BIN_PATH:-/usr/local/bin/amneziawg-go}"
  have_cmd awg && have_cmd awg-quick || return 1
  [[ -e "$sysfs" || -x "$gobin" ]]
}

# Заполняет MODE: install (полная установка) или config (только конфиг)
decide_mode() {
  if [[ $REINSTALL -eq 1 ]]; then
    MODE=install; return 0
  fi
  if [[ $CONFIG_ONLY -eq 1 ]]; then
    is_installed || die "Компоненты AmneziaWG не найдены, --config-only невозможен. Запустите без этого флага."
    MODE=config; return 0
  fi
  if is_installed; then
    log_info "Компоненты AmneziaWG уже установлены."
    if ask_yes_no "Только обновить конфиг, без пересборки модуля и tools?" y; then
      MODE=config
    else
      MODE=install
    fi
  else
    MODE=install
  fi
}

# Печатает подсети из блока exclude-lan установленного конфига через запятую (или ничего)
extract_exclude_subnets() {
  [[ -f "$1" ]] || return 0
  sed -n 's/^PostUp = ip -4 rule add to \([0-9./]*\) lookup main priority 100$/\1/p' "$1" | paste -sd, - | tr -d '\n'
}

# Решает, сохранять ли исключение локальной сети из установленного конфига,
# если пользователь не передал --exclude-lan / --no-exclude-lan.
decide_exclude_lan() {
  local installed="$1" prev
  [[ $EXCLUDE_LAN -eq 1 || $NO_EXCLUDE_LAN -eq 1 ]] && return 0
  prev="$(extract_exclude_subnets "$installed")"
  [[ -n "$prev" ]] || return 0
  log_info "В установленном конфиге локальная сеть исключена из туннеля: ${prev//,/ }"
  if ask_yes_no "Сохранить исключение локальной сети?" y; then
    EXCLUDE_LAN=1; EXCLUDE_LAN_LIST="$prev"
  else
    log_info "Исключение локальной сети будет убрано"
  fi
}

# ---------------------------------------------------------------- версии

github_latest_tag() {
  local out
  out="$(curl -fsSL --max-time 15 "https://api.github.com/repos/amnezia-vpn/$1/tags?per_page=1" 2>/dev/null)" || return 0
  printf '%s' "$out" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(v[^"]*\)".*/\1/p' | head -n1
}

golang_latest_version() {
  local out
  out="$(curl -fsSL --max-time 15 'https://go.dev/dl/?mode=json' 2>/dev/null)" || return 0
  printf '%s' "$out" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\(go[0-9.]*\)".*/\1/p' | head -n1
}

resolve_versions() {
  KMOD_TAG="${AWG_KMOD_TAG:-$(github_latest_tag amneziawg-linux-kernel-module)}"
  TOOLS_TAG="${AWG_TOOLS_TAG:-$(github_latest_tag amneziawg-tools)}"
  GO_TAG="${AWG_GO_TAG:-$(github_latest_tag amneziawg-go)}"
  GOLANG_VERSION="${AWG_GOLANG_VERSION:-$(golang_latest_version)}"
  [[ -n "$KMOD_TAG" ]]  || { KMOD_TAG="$DEFAULT_KMOD_TAG";  log_warn "GitHub недоступен, модуль ядра: $KMOD_TAG"; }
  [[ -n "$TOOLS_TAG" ]] || { TOOLS_TAG="$DEFAULT_TOOLS_TAG"; log_warn "GitHub недоступен, amneziawg-tools: $TOOLS_TAG"; }
  [[ -n "$GO_TAG" ]]    || { GO_TAG="$DEFAULT_GO_TAG";       log_warn "GitHub недоступен, amneziawg-go: $GO_TAG"; }
  [[ -n "$GOLANG_VERSION" ]] || { GOLANG_VERSION="$DEFAULT_GOLANG_VERSION"; log_warn "go.dev недоступен, Go toolchain: $GOLANG_VERSION"; }
}

# ---------------------------------------------------------------- окружение и apt

check_env() {
  [[ $EUID -eq 0 ]] || die "Запустите скрипт от root: sudo $0 ..."
  command -v systemctl >/dev/null || die "Нужна система на systemd"
  command -v apt-get   >/dev/null || die "Поддерживаются только apt-системы (Debian, Ubuntu, Raspberry Pi OS и производные)"
  ARCH="$(dpkg --print-architecture)"
  # shellcheck disable=SC1091
  OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-debian}")"
  log_info "Система: ${OS_ID} ${ARCH}, ядро $(uname -r)"
}

# Выполняет команду, весь вывод — в лог. Возвращает код команды.
run_logged() {
  echo "### $(date '+%F %T') $*" >> "$LOG_FILE"
  "$@" >> "$LOG_FILE" 2>&1
}

apt_install() {
  if [[ $_APT_UPDATED -eq 0 ]]; then
    log_info "apt-get update..."
    run_logged apt-get update || die "apt-get update завершился с ошибкой, см. $LOG_FILE"
    _APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive run_logged apt-get install -y --no-install-recommends "$@"
}

# Печатает кандидатов пакетов заголовков ядра, по одному на строку, в порядке приоритета.
header_candidates() {
  local kver="$1" os="$2" arch="$3"
  echo "linux-headers-$kver"
  if [[ "$kver" == *+rpt* || "$kver" == *-rpi-* ]]; then
    # Raspberry Pi OS Bookworm/Trixie: 6.6.31+rpt-rpi-v8, 6.12.25+rpt-rpi-2712, ...
    case "$kver" in
      *2712*)     echo "linux-headers-rpi-2712" ;;
      *-rpi-v7l*) echo "linux-headers-rpi-v7l" ;;
      *-rpi-v7*)  echo "linux-headers-rpi-v7" ;;
      *)          echo "linux-headers-rpi-v8" ;;
    esac
    echo "raspberrypi-kernel-headers"
  elif [[ "$kver" =~ -v[678]l?\+$ ]]; then
    # Raspberry Pi OS Bullseye и старше: 6.1.21-v8+, 5.15.84-v7l+
    echo "raspberrypi-kernel-headers"
  fi
  if [[ "$kver" == *-raspi* ]]; then echo "linux-headers-raspi"; fi
  case "$os" in
    ubuntu) echo "linux-headers-generic" ;;
    *)      echo "linux-headers-$arch" ;;
  esac
}

install_kernel_headers() {
  local pkg
  while read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if apt-cache show "$pkg" >/dev/null 2>&1 && apt_install "$pkg"; then
      log_ok "Установлены заголовки ядра: $pkg"
      return 0
    fi
  done < <(header_candidates "$(uname -r)" "$OS_ID" "$ARCH")
  return 1
}

# ---------------------------------------------------------------- модуль ядра

git_clone_tag() { # repo tag dest
  run_logged git clone --depth 1 --branch "$2" "https://github.com/amnezia-vpn/$1.git" "$3"
}

install_kernel_module() {
  local kver; kver="$(uname -r)"
  log_info "Установка заголовков ядра..."
  if ! install_kernel_headers; then
    log_warn "Не удалось установить заголовки ядра для $kver"; return 1
  fi
  if [[ ! -d "/lib/modules/$kver/build" ]]; then
    log_warn "Нет /lib/modules/$kver/build. Вероятно, ядро обновлено, но система не перезагружена."
    log_warn "Перезагрузитесь и запустите скрипт снова, чтобы получить модуль ядра."
    return 1
  fi
  apt_install dkms || { log_warn "Не удалось установить dkms"; return 1; }
  log_info "Сборка модуля ядра amneziawg ($KMOD_TAG) через DKMS, это займёт несколько минут..."
  git_clone_tag amneziawg-linux-kernel-module "$KMOD_TAG" "$WORK_DIR/kmod" \
    || { log_warn "Не удалось скачать исходники модуля ($KMOD_TAG)"; return 1; }
  if dkms status -m "$DKMS_NAME" -v "$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME"; then
    run_logged dkms remove -m "$DKMS_NAME" -v "$DKMS_VER" --all || true
  fi
  rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VER}"
  run_logged make -C "$WORK_DIR/kmod/src" dkms-install PREFIX=/usr || { log_warn "make dkms-install не удался"; return 1; }
  run_logged dkms add -m "$DKMS_NAME" -v "$DKMS_VER" || { log_warn "dkms add не удался"; return 1; }
  if ! run_logged dkms build -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kver"; then
    log_warn "Сборка модуля не удалась. Хвост make.log:"
    tail -n 20 "/var/lib/dkms/$DKMS_NAME/$DKMS_VER/build/make.log" 2>/dev/null >&2 || true
    return 1
  fi
  run_logged dkms install -m "$DKMS_NAME" -v "$DKMS_VER" -k "$kver" --force || { log_warn "dkms install не удался"; return 1; }
  run_logged depmod -a "$kver" || true
  if ! modprobe amneziawg 2>>"$LOG_FILE"; then
    log_warn "Модуль собран, но modprobe amneziawg не загрузил его"; return 1
  fi
  [[ -e /sys/module/amneziawg ]] || { log_warn "Модуль не виден в /sys/module"; return 1; }
  log_ok "Модуль ядра amneziawg загружен"
  IMPL="kernel"
}

# ---------------------------------------------------------------- userspace (amneziawg-go)

golang_arch() {
  case "$ARCH" in
    arm64)       echo arm64 ;;
    armhf|armel) echo armv6l ;;
    amd64)       echo amd64 ;;
    i386)        echo 386 ;;
    *) die "Нет Go toolchain для архитектуры $ARCH" ;;
  esac
}

install_userspace() {
  local goarch tc="$WORK_DIR/go-toolchain" tarball
  goarch="$(golang_arch)"
  tarball="${GOLANG_VERSION}.linux-${goarch}.tar.gz"
  log_info "Скачивание Go toolchain $GOLANG_VERSION ($goarch)..."
  mkdir -p "$tc"
  curl -fsSL --retry 3 "https://go.dev/dl/$tarball" -o "$WORK_DIR/$tarball" || die "Не удалось скачать $tarball"
  tar -C "$tc" -xzf "$WORK_DIR/$tarball" || die "Не удалось распаковать Go toolchain"
  log_info "Сборка amneziawg-go ($GO_TAG), это займёт несколько минут..."
  git_clone_tag amneziawg-go "$GO_TAG" "$WORK_DIR/awg-go" || die "Не удалось скачать исходники amneziawg-go ($GO_TAG)"
  (
    cd "$WORK_DIR/awg-go" \
      && PATH="$tc/go/bin:$PATH" GOFLAGS=-mod=mod GOPATH="$WORK_DIR/gopath" GOCACHE="$WORK_DIR/gocache" GOTOOLCHAIN=local \
         run_logged make
  ) || die "Сборка amneziawg-go не удалась, см. $LOG_FILE"
  install -m 0755 "$WORK_DIR/awg-go/amneziawg-go" /usr/local/bin/amneziawg-go
  log_ok "amneziawg-go установлен в /usr/local/bin/amneziawg-go"
  IMPL="userspace"
}

# ---------------------------------------------------------------- amneziawg-tools

install_tools() {
  log_info "Сборка amneziawg-tools ($TOOLS_TAG)..."
  git_clone_tag amneziawg-tools "$TOOLS_TAG" "$WORK_DIR/tools" || die "Не удалось скачать исходники amneziawg-tools ($TOOLS_TAG)"
  run_logged make -C "$WORK_DIR/tools/src" || die "Сборка amneziawg-tools не удалась, см. $LOG_FILE"
  run_logged make -C "$WORK_DIR/tools/src" install WITH_SYSTEMDUNITS=yes WITH_WGQUICK=yes WITH_BASHCOMPLETION=yes \
    || die "Установка amneziawg-tools не удалась, см. $LOG_FILE"
  run_logged systemctl daemon-reload || true
  if ! command -v awg >/dev/null || ! command -v awg-quick >/dev/null; then
    die "awg/awg-quick не найдены после установки"
  fi
  log_ok "amneziawg-tools установлены: $(awg --version 2>/dev/null | head -n1)"
}

# ---------------------------------------------------------------- DNS, конфиг, запуск

ensure_dns_support() {
  config_has_dns "$1" || return 0
  command -v resolvconf >/dev/null && return 0
  if systemctl is-active --quiet systemd-resolved; then
    log_warn "В конфиге есть DNS, но команды resolvconf нет, а systemd-resolved активен."
    log_warn "Установите пакет systemd-resolved (он даёт совместимый resolvconf) или уберите строку DNS из конфига."
    return 0
  fi
  log_info "В конфиге есть DNS: устанавливаю openresolv..."
  apt_install openresolv || log_warn "Не удалось установить openresolv, строка DNS работать не будет"
}

# Копирует конфиг в каталог AmneziaWG. Результат: DST_CONF (путь) и CONFIG_CHANGED (0/1).
install_config() {
  local src="$1" iface="$2" dir="${CONF_DIR_OVERRIDE:-$CONF_DIR}"
  DST_CONF="$dir/$iface.conf"; CONFIG_CHANGED=1
  install -d -m 0700 "$dir"
  if [[ -f "$DST_CONF" ]]; then
    if cmp -s "$src" "$DST_CONF"; then
      CONFIG_CHANGED=0
      chmod 0600 "$DST_CONF"
      return 0
    fi
    cp -p "$DST_CONF" "$DST_CONF.bak.$(date +%Y%m%d%H%M%S)"
    log_warn "Прежний конфиг сохранён как $DST_CONF.bak.*"
  fi
  install -m 0600 "$src" "$DST_CONF"
}

# 0 — можно запускать туннель, 1 — пользователь отказался.
confirm_ssh_risk() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 0
  config_is_full_tunnel "$1" || return 0
  local client="${SSH_CONNECTION%% *}" c
  if [[ "$client" =~ ^[0-9.]+$ ]]; then
    for c in "${EXCLUDE_SUBNETS[@]}"; do
      if ip_in_cidr "$client" "$c"; then
        log_info "SSH-клиент $client в исключённой подсети $c, туннель сессию не затронет"
        return 0
      fi
    done
  fi
  log_warn "Вы подключены по SSH, а конфиг направляет весь трафик (0.0.0.0/0) в туннель."
  ask_yes_no "После запуска SSH-сессия может оборваться. Продолжить запуск?" n
}

start_tunnel() {
  local iface="$1" changed="${2:-1}" unit="awg-quick@$1"
  if systemctl is-active --quiet "$unit"; then
    if [[ "$changed" -eq 0 ]]; then
      log_info "Конфиг не изменился, туннель уже работает, перезапуск не нужен"
      run_logged systemctl enable "$unit" || true
      return 0
    fi
    log_info "Перезапуск $unit..."
    run_logged systemctl restart "$unit" || die "Не удалось перезапустить $unit. Смотрите: journalctl -u $unit"
    run_logged systemctl enable "$unit" || true
  else
    log_info "Запуск и включение автозапуска $unit..."
    run_logged systemctl enable --now "$unit" || die "Не удалось запустить $unit. Смотрите: journalctl -u $unit"
  fi
  log_info "Ожидание handshake (до 20 с)..."
  local _try
  for _try in $(seq 1 20); do
    if awg show "$iface" latest-handshakes 2>/dev/null | awk '{ if ($2 > 0) found=1 } END { exit !found }'; then
      log_ok "Handshake с сервером установлен"
      return 0
    fi
    sleep 1
  done
  log_warn "Handshake не получен за 20 с. Проверьте Endpoint, ключи и параметры обфускации (S1-S4, H1-H4 должны совпадать с сервером)."
}

print_summary() {
  local iface="$1" dst="$2"
  echo
  if [[ "$MODE" == config ]]; then
    log_ok "Конфиг обновлён"
    echo "  Режим:           только конфиг (компоненты не трогались)"
    echo "  Реализация:      ${IMPL:-неизвестна}"
    echo "  amneziawg-tools: $(awg --version 2>/dev/null | head -n1)"
  else
    log_ok "Установка завершена"
    echo "  Режим:           полная установка"
    echo "  Реализация:      ${IMPL:-не установлена}"
    [[ "$IMPL" == "kernel" ]]    && echo "  Модуль ядра:     $KMOD_TAG (DKMS, пересобирается при обновлении ядра)"
    [[ "$IMPL" == "userspace" ]] && echo "  amneziawg-go:    $GO_TAG (/usr/local/bin/amneziawg-go)"
    echo "  amneziawg-tools: $TOOLS_TAG"
  fi
  echo "  Конфиг:          $dst"
  (( ${#EXCLUDE_SUBNETS[@]} > 0 )) && echo "  Вне туннеля:     ${EXCLUDE_SUBNETS[*]}"
  echo "  Лог установки:   $LOG_FILE"
  echo
  echo "Управление:"
  echo "  sudo $0 <client.conf> --config-only   # применить новый конфиг"
  echo "  sudo awg show $iface"
  echo "  sudo systemctl status awg-quick@$iface"
  echo "  sudo systemctl stop|start|restart awg-quick@$iface"
  echo "  sudo systemctl disable awg-quick@$iface   # отключить автозапуск"
}

cleanup() { if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi; }

# ---------------------------------------------------------------- main

main() {
  parse_args "$@"
  check_env
  validate_config "$CONF_SRC"
  touch "$LOG_FILE"; chmod 0600 "$LOG_FILE"
  WORK_DIR="$(mktemp -d /tmp/awg-client.XXXXXX)"; trap cleanup EXIT
  decide_mode
  decide_exclude_lan "$CONF_DIR/$IFACE.conf"
  local conf_to_install="$CONF_SRC"
  if [[ $EXCLUDE_LAN -eq 1 ]]; then
    if config_is_full_tunnel "$CONF_SRC"; then
      resolve_exclude_subnets
      log_info "Вне туннеля останутся локальные подсети: ${EXCLUDE_SUBNETS[*]}"
      conf_to_install="$WORK_DIR/$IFACE.conf"
      apply_exclude_lan "$CONF_SRC" "$conf_to_install" "${EXCLUDE_SUBNETS[@]}"
    else
      log_warn "--exclude-lan: конфиг не направляет весь трафик в туннель (нет 0.0.0.0/0), флаг не нужен, пропускаю"
    fi
  fi
  if [[ "$MODE" == install ]]; then
    resolve_versions
    log_info "Установка базовых зависимостей..."
    apt_install ca-certificates curl git build-essential make pkg-config \
      || die "Не удалось установить базовые пакеты, см. $LOG_FILE"
    if [[ $USERSPACE -eq 1 ]]; then
      log_info "Режим --userspace: модуль ядра пропускаем"
      install_userspace
    elif ! install_kernel_module; then
      log_warn "Переход на userspace-реализацию amneziawg-go"
      install_userspace
    fi
    install_tools
  else
    log_info "Режим: только обновление конфига"
    if [[ -e /sys/module/amneziawg ]]; then IMPL="kernel"
    elif [[ -x /usr/local/bin/amneziawg-go ]]; then IMPL="userspace"; fi
  fi
  ensure_dns_support "$CONF_SRC"
  install_config "$conf_to_install" "$IFACE"
  if [[ $CONFIG_CHANGED -eq 1 ]]; then
    log_ok "Конфиг установлен: $DST_CONF"
  else
    log_info "Конфиг не изменился: $DST_CONF"
  fi
  if [[ $NO_START -eq 1 ]]; then
    log_info "--no-start: туннель не запускаю. Запуск: sudo systemctl enable --now awg-quick@$IFACE"
  elif confirm_ssh_risk "$CONF_SRC"; then
    start_tunnel "$IFACE" "$CONFIG_CHANGED"
    awg show "$IFACE" 2>/dev/null || true
  else
    log_info "Запуск отменён. Позже: sudo systemctl enable --now awg-quick@$IFACE"
  fi
  print_summary "$IFACE" "$DST_CONF"
}

# Запускаем main при прямом вызове и при `curl ... | bash -s -- ...` (BASH_SOURCE пуст),
# но не при подключении через source (тесты).
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
