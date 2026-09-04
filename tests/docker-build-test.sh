#!/usr/bin/env bash
# Интеграционный тест сборки в debian:bookworm (arm64): amneziawg-tools, amneziawg-go
# и DKMS-модуль против пакета linux-headers-arm64. Загрузку модуля не проверяет.
set -euo pipefail
cd "$(dirname "$0")/.."
PLATFORM="${PLATFORM:-linux/arm64}"
docker run --rm --platform "$PLATFORM" -v "$PWD:/src:ro" debian:bookworm bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl git build-essential make pkg-config dkms linux-headers-arm64 kmod >/dev/null
  cp /src/install-awg-client.sh /tmp/i.sh
  # shellcheck source=/dev/null
  source /tmp/i.sh
  set -e
  ARCH=$(dpkg --print-architecture); OS_ID=debian
  WORK_DIR=$(mktemp -d); touch "$LOG_FILE"
  resolve_versions
  echo "== tags: kmod=$KMOD_TAG tools=$TOOLS_TAG go=$GO_TAG golang=$GOLANG_VERSION"
  install_tools
  awg --version
  install_userspace
  /usr/local/bin/amneziawg-go --version
  KVER=$(ls /lib/modules | head -n1)
  echo "== headers kernel: $KVER"
  git_clone_tag amneziawg-linux-kernel-module "$KMOD_TAG" "$WORK_DIR/kmod"
  make -C "$WORK_DIR/kmod/src" dkms-install PREFIX=/usr >>"$LOG_FILE" 2>&1
  dkms add -m amneziawg -v 1.0.0 >>"$LOG_FILE" 2>&1
  if ! dkms build -m amneziawg -v 1.0.0 -k "$KVER" >>"$LOG_FILE" 2>&1; then
    echo "== DKMS BUILD FAILED, tail of make.log:"; tail -n 40 /var/lib/dkms/amneziawg/1.0.0/build/make.log; exit 1
  fi
  ls -la /var/lib/dkms/amneziawg/1.0.0/"$KVER"/*/module/
  modinfo /var/lib/dkms/amneziawg/1.0.0/"$KVER"/*/module/amneziawg.ko* | head -n 8
  echo DOCKER-BUILD-OK
'
