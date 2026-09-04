# amneziawg-client-installer

[![CI](https://github.com/ekuraev/amneziawg-client-installer/actions/workflows/ci.yml/badge.svg)](https://github.com/ekuraev/amneziawg-client-installer/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ekuraev/amneziawg-client-installer)](https://github.com/ekuraev/amneziawg-client-installer/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Один скрипт, который превращает любую машину на Debian, Ubuntu или их
производных (x86_64, arm64, armhf: сервер, ноутбук, мини-ПК, Raspberry Pi) в
**клиент** AmneziaWG. Никакой серверной части: только модуль, утилиты, ваш
готовый конфиг и автозапуск.

Что делает скрипт:

1. Ставит заголовки ядра и собирает модуль `amneziawg` через DKMS
   (модуль автоматически пересобирается при обновлении ядра).
2. Если модуль собрать не удалось (или указан `--userspace`), собирает
   userspace-реализацию `amneziawg-go`. Go toolchain скачивается во временный
   каталог и после сборки удаляется, системный Go не трогается.
3. Собирает `amneziawg-tools` (`awg`, `awg-quick`, юнит `awg-quick@`).
4. Кладёт ваш конфиг в `/etc/amnezia/amneziawg/awg0.conf` (права 600).
5. Включает автозапуск `awg-quick@awg0` и ждёт handshake с сервером.

Маршруты скрипт не трогает: применяется ровно то, что описано в `AllowedIPs`
вашего конфига.

## Требования

- Debian 12+, Ubuntu 22.04+, Raspberry Pi OS (Bookworm/Trixie, 32 или 64 бит).
  Другие apt-системы с systemd, скорее всего, тоже подойдут.
- Архитектура x86_64, arm64 или armhf.
- Доступ в интернет (GitHub, go.dev, репозитории apt).
- Готовый клиентский конфиг AmneziaWG в формате `awg-quick`
  (экспорт из приложения AmneziaVPN или файл с вашего сервера).
- Свободное место: около 1 ГБ на время сборки (headers, build-essential, Go).

## Быстрый старт одной командой

Скопируйте клиентский конфиг на целевую машину (например,
`scp client.conf user@host:~/`), затем на ней:

```bash
curl -fsSL https://github.com/ekuraev/amneziawg-client-installer/releases/latest/download/install-awg-client.sh | sudo bash -s -- ~/client.conf
```

Команда скачивает скрипт из последнего релиза и передаёт ему путь к вашему
конфигу. Все флаги (см. ниже) добавляются после `--`, например
`sudo bash -s -- ~/client.conf --exclude-lan` или
`sudo bash -s -- ~/new-client.conf --config-only`.

Вариант с проверкой контрольной суммы:

```bash
BASE=https://github.com/ekuraev/amneziawg-client-installer/releases/latest/download
curl -fsSLO "$BASE/install-awg-client.sh" -O "$BASE/install-awg-client.sh.sha256"
sha256sum -c install-awg-client.sh.sha256
sudo bash install-awg-client.sh ~/client.conf
```

Из клона репозитория:

```bash
git clone https://github.com/ekuraev/amneziawg-client-installer.git
cd amneziawg-client-installer
sudo ./install-awg-client.sh ~/client.conf
```

Полная установка занимает от минуты на x86_64 до 5–10 минут на Raspberry Pi 4,
большая часть времени уходит на сборку модуля ядра.

## Параметры

```
sudo ./install-awg-client.sh <client.conf> [--iface NAME] [--exclude-lan[=CIDR,...]] [--config-only|--reinstall] [--userspace] [--no-start]
```

| Параметр      | Описание                                                       |
|---------------|----------------------------------------------------------------|
| `<client.conf>` | Путь к клиентскому конфигу (обязательный).                   |
| `--iface NAME`  | Имя интерфейса. По умолчанию `awg0`.                         |
| `--exclude-lan` | Оставить локальные IPv4-подсети вне туннеля (см. ниже).      |
| `--exclude-lan=CIDR,...` | То же, но со своим списком подсетей, например `192.168.0.0/16,10.0.0.0/24`. |
| `--no-exclude-lan` | Убрать исключение локальной сети из установленного конфига. |
| `--config-only` | Компоненты уже стоят: только применить конфиг и перезапустить туннель. |
| `--reinstall`   | Полная переустановка без вопросов, обновляет модуль и tools. |
| `--userspace`   | Не собирать модуль ядра, сразу ставить `amneziawg-go`.       |
| `--no-start`    | Установить всё и скопировать конфиг, но не поднимать туннель. |
| `--version`     | Версия скрипта.                                              |
| `-h`, `--help`  | Справка.                                                     |

Переменные окружения для фиксации версий (по умолчанию берутся последние теги
с GitHub, при недоступности сети используются зашитые в скрипт):

```bash
sudo AWG_KMOD_TAG=v3.1.20260828 AWG_TOOLS_TAG=v3.1.20260812 ./install-awg-client.sh client.conf
```

| Переменная           | Что фиксирует                                  |
|----------------------|------------------------------------------------|
| `AWG_KMOD_TAG`       | тег `amneziawg-linux-kernel-module`            |
| `AWG_TOOLS_TAG`      | тег `amneziawg-tools`                          |
| `AWG_GO_TAG`         | тег `amneziawg-go`                             |
| `AWG_GOLANG_VERSION` | версия Go toolchain, например `go1.27.1`       |

## Управление туннелем

```bash
sudo awg show awg0                          # состояние, handshake, трафик
sudo systemctl status awg-quick@awg0
sudo systemctl restart awg-quick@awg0
sudo systemctl disable --now awg-quick@awg0 # выключить и убрать из автозапуска
sudo journalctl -u awg-quick@awg0           # логи запуска
```

Лог установки: `/var/log/awg-client-install.log`.

## Если нет handshake

Скрипт ждёт handshake 20 секунд и выводит предупреждение, если его нет.
Установка при этом считается успешной, проблема почти всегда в конфиге или сети:

- Проверьте `Endpoint` и доступность порта сервера (UDP).
- Параметры `S1`–`S4`, `H1`–`H4` и, для AWG 3, `HeaderProtectionKey` должны
  **совпадать** с сервером. `Jc`, `Jmin`, `Jmax`, `I1`–`I5` могут отличаться.
- Убедитесь, что версия протокола на сервере не новее, чем у клиента:
  `awg --version` на обеих сторонах.
- Смотрите `sudo journalctl -u awg-quick@awg0` и `dmesg | grep -i amnezia`.

## Важные особенности

**SSH и полный туннель.** Если в конфиге `AllowedIPs = 0.0.0.0/0`, после
запуска весь трафик машины, включая вашу SSH-сессию, пойдёт через VPN. Скрипт
предупредит об этом и спросит подтверждение. Безопасный вариант: запустить с
`--no-start`, а туннель поднять с локальной консоли, либо использовать
split-конфиг с конкретными подсетями.

**Локальная сеть и `--exclude-lan`.** При `AllowedIPs = 0.0.0.0/0` awg-quick
сам добавляет правило `suppress_prefixlength 0`, поэтому подсеть, к которой машина
подключена напрямую (например `192.168.1.0/24` на `eth0`), и так остаётся вне
туннеля. Флаг `--exclude-lan` делает это явной гарантией и покрывает случаи,
когда этого недостаточно: соседние подсети за домашним роутером,
`Table = off` в конфиге, доступ из другого VLAN. Скрипт определяет подсети
физических интерфейсов (`ip -4 route show scope link`, VPN и docker
отбрасываются) или берёт список из `--exclude-lan=192.168.0.0/16,10.0.0.0/24`
и добавляет в `[Interface]` установленного конфига строки вида:

```
PostUp = ip -4 rule add to 192.168.1.0/24 lookup main priority 100
PreDown = ip -4 rule del to 192.168.1.0/24 lookup main priority 100 || true
```

Исходный файл конфига не меняется, `AllowedIPs` тоже. При повторном запуске
блок пересоздаётся. Ограничение: только IPv4. Если SSH-клиент находится в
исключённой подсети, предупреждение о разрыве сессии не показывается.

**DNS.** Строка `DNS =` в конфиге применяется через `resolvconf`. На Debian и
Raspberry Pi OS его обычно нет, и скрипт поставит `openresolv`. Если активен
`systemd-resolved` (типично для Ubuntu), скрипт ничего не ставит и попросит
либо установить пакет `systemd-resolved` (он даёт совместимый `resolvconf`),
либо убрать строку `DNS`.

**Обновление ядра без перезагрузки.** Если `apt upgrade` обновил ядро, но
система не перезагружалась, каталога `/lib/modules/$(uname -r)/build` не
будет, и модуль собрать нельзя. Скрипт об этом скажет и уйдёт в userspace.
Перезагрузитесь и запустите скрипт снова, чтобы получить модуль ядра.

**Модуль ядра и userspace.** Модуль ядра быстрее и не нагружает CPU.
`amneziawg-go` работает везде, но на слабом железе ограничивает скорость
(на Raspberry Pi 4 примерно 100–200 Мбит/с). Какой вариант установлен, видно
в итоговой сводке скрипта.
Если в системе есть и модуль, и `amneziawg-go`, `awg-quick` использует модуль.

## Обновление конфига и компонентов

Скрипт замечает, что AmneziaWG уже установлен, и спрашивает, обновить ли
только конфиг. Ответ по умолчанию: да. Без терминала (например, при запуске
из скрипта) тоже обновляется только конфиг.

```bash
# Применить новый конфиг (секунды, без пересборки)
sudo ./install-awg-client.sh new-client.conf --config-only

# Старый конфиг, но нужно исключить локальную сеть
sudo ./install-awg-client.sh client.conf --config-only --exclude-lan

# Обновить модуль ядра и amneziawg-tools до свежих версий
sudo ./install-awg-client.sh client.conf --reinstall
```

Что происходит при обновлении конфига:

- Новый конфиг (после применения `--exclude-lan`) сравнивается с установленным.
  Если он отличается, старый сохраняется как `awg0.conf.bak.<дата>` и туннель
  перезапускается. Если совпадает, перезапуска нет.
- Если в установленном конфиге было исключение локальной сети, а флаг
  `--exclude-lan` не передан, скрипт спросит, сохранить ли его (по умолчанию
  да, подсети берутся прежние). `--no-exclude-lan` убирает исключение без
  вопроса.

## Удаление

```bash
sudo systemctl disable --now awg-quick@awg0
sudo dkms remove -m amneziawg -v 1.0.0 --all
sudo rm -rf /usr/src/amneziawg-1.0.0
sudo rm -f /usr/bin/awg /usr/bin/awg-quick /usr/local/bin/amneziawg-go
sudo rm -f /lib/systemd/system/awg-quick@.service /lib/systemd/system/awg-quick.target
sudo rm -f /usr/share/bash-completion/completions/awg /usr/share/bash-completion/completions/awg-quick
sudo rm -rf /etc/amnezia
sudo systemctl daemon-reload
```

Пакеты `dkms`, `build-essential`, заголовки ядра и `openresolv` при желании
удалите через `apt`.

## Тесты

```bash
bash tests/test_installer.sh        # юнит-тесты чистых функций, без root и сети
shellcheck install-awg-client.sh tests/*.sh
bash tests/docker-build-test.sh     # сборка tools, amneziawg-go и DKMS-модуля в debian:bookworm arm64
```

Docker-тест проверяет только сборку. Загрузка модуля и реальный туннель
проверяются на реальной машине.

CI на GitHub гоняет shellcheck, юнит-тесты и Docker-сборку на arm64-раннере
при каждом push. Релиз создаётся автоматически по тегу `v*`: в скрипт
подставляется версия, публикуются `install-awg-client.sh` и его sha256.

## Чем отличается от bivlked/amneziawg-installer

[bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer)
устанавливает **сервер** AmneziaWG. Этот проект устанавливает исключительно
**клиент**.

## Участие

Идеи и баги: [Issues](https://github.com/ekuraev/amneziawg-client-installer/issues).
Перед PR прогоните `shellcheck install-awg-client.sh tests/*.sh` и
`bash tests/test_installer.sh`.

## Лицензия

[MIT](LICENSE).
