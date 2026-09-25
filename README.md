# rw-node-installer

[![verify](https://github.com/penatov/rw-node-installer/actions/workflows/verify.yml/badge.svg)](https://github.com/penatov/rw-node-installer/actions/workflows/verify.yml)
[![Debian 12/13](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Интерактивный установщик Remnawave Node для **чистой Debian 12 или 13**. Он разворачивает Node в Docker, локальный self-steal-сайт на Caddy, сертификаты для Hysteria2, постоянный nftables firewall, адаптивный сетевой тюнинг и обновление образа `remnawave/node:latest` с health-check и автоматическим откатом.

Проект рассчитан на профиль с двумя публичными inbound на одном адресе:

- VLESS TCP REALITY — `443/tcp`, target `127.0.0.1:8443`;
- Hysteria2 — `443/udp`, сертификат Caddy и proxy masquerade на локальный сайт.

Установщик не подключается к API панели и ничего в ней не создаёт. После установки он печатает значения и рекомендации, которые нужно перенести в панель вручную.

## Что именно настраивается

- официальный Docker Engine и Compose plugin;
- официальный стабильный Caddy;
- `remnawave/node:latest` в host network с `NET_ADMIN` для Node Plugins;
- уникальный сайт из `tools/site_generator.sh` (Bash + штатный awk), локальные WOFF2-шрифты без Google Fonts; генератор не требует Python;
- сертификат ACME HTTP-01 на Caddy и его безопасная копия в `/etc/ssl/hysteria`;
- отдельная таблица `inet rw_node_guard`, не удаляющая таблицы Remnawave Plugins;
- SSH `22/tcp` только от IP панели и списка администраторов;
- Node API на выбранном TCP-порту (по умолчанию `2222`) только от IP панели;
- публичные `80/tcp`, `443/tcp`, `443/udp`; запрещённые TCP-подключения получают RST (`closed` при обычном сканировании), прочий неразрешённый трафик отбрасывается;
- IPv4 и IPv6 в одном ruleset; IPv6 используется автоматически, если настроен у провайдера;
- BBR+fq при наличии в ядре, безопасные sysctl, лимиты журналов и осторожный NIC/RPS-тюнинг;
- ежедневная проверка `latest`, health-check и возврат к последнему рабочему image digest;
- security-only unattended upgrades без автоматической перезагрузки.

## Структура репозитория

```text
rw-node-installer/
├── src/                 runtime: CLI, shell-модули, systemd units и служебные scripts
├── tools/               самостоятельный Bash/awk-генератор сайта
├── assets/              локальные шрифты и статические файлы сайта
├── docs/                архитектура, эксплуатация и рекомендации профиля
├── tests/               статические и unit-проверки
├── .github/workflows/   Linux CI
└── install.sh           минимальный локальный/удалённый bootstrap
```

В корне оставлены только файлы, которые обычно ожидаются у GitHub-проекта. Содержимое
`src/` при установке собирается в `/usr/local/lib/rw-node-installer`; структура репозитория
не становится частью публичного API ноды.

## Перед установкой

Нужны:

1. Чистая Debian 12/13 `amd64` или `arm64` с systemd.
2. A-запись домена на IPv4 ноды. AAAA необязательна: без неё установщик выдаст предупреждение и продолжит только с IPv4. Если AAAA опубликована, IPv6 ноды обязан работать.
3. Внешние firewall/security groups провайдера должны пропускать `80/tcp`, `443/tcp`, `443/udp`, а также `22/tcp` и выбранный TCP-порт API (по умолчанию `2222`) от соответствующих доверенных адресов.
4. `SECRET_KEY`, созданный панелью Remnawave.
5. IP панели и один или несколько IP/CIDR администратора.

Если сервер уже содержит чужой Caddy, Docker, firewall или данные в `/opt/remnanode`, сначала разберите конфликт вручную. Установщик специально ориентирован на чистую систему и отказывается продолжать при занятых портах.

## Установка

Запускайте из root-shell. Команда ниже закреплена за проверенным GitHub Actions commit,
указанным в `COMMIT_SHA`: и bootstrap, и архив загружаются из одного
неизменяемого commit. Для последующих версий заменяйте SHA только на полный 40-символьный
идентификатор коммита с успешно пройденным workflow `verify`.

```bash
apt-get -o DPkg::Lock::Timeout=600 update && apt-get -o DPkg::Lock::Timeout=600 install -y ca-certificates curl tar && (COMMIT_SHA=dd0f311393f92300cec1f21a967e125b531e4cda; RW_BOOTSTRAP_FILE=$(mktemp) && trap 'rm -f -- "$RW_BOOTSTRAP_FILE"' EXIT && curl -fsSL "https://raw.githubusercontent.com/penatov/rw-node-installer/${COMMIT_SHA}/install.sh" -o "$RW_BOOTSTRAP_FILE" && env RW_INSTALLER_REPO=https://github.com/penatov/rw-node-installer RW_INSTALLER_REF="$COMMIT_SHA" bash "$RW_BOOTSTRAP_FILE")
```

Для обновления только firewall на уже установленной ноде, из root-shell:

```bash
(
  set -e
  COMMIT_SHA=dd0f311393f92300cec1f21a967e125b531e4cda
  RW_BOOTSTRAP_FILE=$(mktemp)
  trap 'rm -f -- "$RW_BOOTSTRAP_FILE"' EXIT
  curl -fsSL "https://raw.githubusercontent.com/penatov/rw-node-installer/${COMMIT_SHA}/install.sh" -o "$RW_BOOTSTRAP_FILE"
  env RW_INSTALLER_REPO=https://github.com/penatov/rw-node-installer RW_INSTALLER_REF="$COMMIT_SHA" bash "$RW_BOOTSTRAP_FILE" --firewall-only
)
```

Whitelist берётся из сохранённых настроек. Ключи, контейнер и профиль панели
не меняются. Откройте новую SSH-сессию и подтвердите `yes` за 150 секунд;
без подтверждения firewall откатится. [Подробности и проверка](docs/OPERATIONS.md#обновление-правил-без-переустановки).

Из локального клона, также в root-shell:

```bash
./install.sh
```

Будут запрошены:

- домен ноды;
- `SECRET_KEY` (ввод скрыт);
- TCP-порт API ноды — Enter оставляет `2222`;
- один IPv4 или IPv6 панели;
- IP/CIDR администраторов через запятую;
- необязательный email для ACME.

Неинтерактивные параметры описаны в `rw-node help`; секрет передаётся только через `RW_SECRET_KEY`. Помните, что переменная окружения root-процесса потенциально доступна средствам диагностики системы — интерактивный скрытый ввод предпочтительнее.

Порт можно передать заранее: `./install.sh --node-port 32456` или через
`RW_NODE_PORT=32456`. Приоритет: `--node-port`, затем `RW_NODE_PORT`, затем
сохранённое значение. При первой установке без TTY и без явного значения
используется 2222. Разрешены свободные порты 1–65535, кроме 22, 80, 443 и 8443,
занятых службами проекта. Порт сохраняется и используется в Node, nftables,
диагностике и health-check. В записи ноды в панели вручную задайте тот же
**Node port**. Порты клиентских подключений VLESS/Hysteria2 остаются 443.

## После установки

Установщик выдаст REALITY target, пути сертификатов, proxy masquerade Hysteria2, публичную часть новой X25519-пары и short IDs. Private key остаётся в root-only state и показывается только явной TTY-командой. Полный рекомендуемый фрагмент профиля находится в [docs/PROFILE.md](docs/PROFILE.md).

Основные команды:

```bash
rw-node status
rw-node diagnose
rw-node firewall
rw-node profile-guidance
rw-node profile-guidance --show-private-key
rw-node regenerate-site
rw-node cert-sync
rw-node update-node
```

Удаление управляемых файлов и сервисов:

```bash
rw-node uninstall
```

Добавьте `--purge-packages`, только если Docker и Caddy не нужны другим приложениям. Подробнее — в [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Модель защиты и ограничения

nftables надёжно скрывает административные порты от недоверенных источников и сокращает поверхность атаки, но **не способен гарантировать “нулевую обнаруживаемость” публичного VPN**. Легитимные клиенты и сканер видят один и тот же открытый `443`; распознавание может строиться на активном протоколировании, статистике трафика, репутации IP или данных провайдера. На корректный обычный TLS-запрос REALITY ведёт к настоящему сайту Caddy, а Hysteria2 следует настроить на proxy masquerade. Это снижает количество очевидных признаков, но не является математической гарантией обхода DPI/ТСПУ.

Не включены сомнительные «магические» настройки вроде отключения ICMPv6, глобального `flush ruleset`, безусловного выключения offload или экстремальных socket buffers: они чаще ломают сеть или снижают производительность. Архитектура и границы доверия описаны в [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), разбор TrafficGuard/node-accelerator и других решений — в [docs/DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md), политика безопасности — в [SECURITY.md](SECURITY.md).

## Проверка репозитория

```bash
bash tests/test-static.sh
bash tests/test-units.sh
bash tests/test-no-python.sh
bash tests/test-site-generator.sh
bash tests/test-ip-parser.sh
bash tools/site_generator.sh --audit 100 --seed repository-audit
```

GitHub Actions дополнительно запускает ShellCheck, синтаксическую проверку nftables, адаптацию Caddyfile и `docker compose config`.
Тесты написаны на Bash/awk; сетевые проверки используют `socat` и `netcat-openbsd`
только в CI, эти пакеты не добавляются на ноду.

### Генератор без Python

На ноде генерация выполняется через Bash, штатный `awk` (`mawk` на Debian) и coreutils.
В текущем дереве репозитория нет Python-исходников; конвертер и старый эталон также
удалены, проверки заменены Bash/awk-тестами с фиксированными контрольными данными.
Проверки IP/CIDR, ключа панели, DNS и настройка сетевых очередей также не требуют Python.
Явная зависимость нашего кода от `python3` удалена; уже установленные пакеты не удаляются.
Однако системный `unattended-upgrades` по-прежнему устанавливает Python как свою зависимость:
автообновления безопасности сохранены. Это перенос генератора и нашего runtime без Python,
а не гарантия отсутствия Python среди системных пакетов.

Сохранены все семейства шаблонов, CSS, правила выбора и сочетания секций. Служебные
надписи `DNA / SYSTEM / MODE / GRID` заменены обычным содержимым подвала. Один seed
в новой версии воспроизводим, разные seed дают разные комбинации; старый seed
может дать другой сайт из-за смены генератора случайных чисел. Существующий сайт
не перезаписывается при обычной повторной установке. Для его замены после обновления
runtime используется `rw-node regenerate-site`.

Описание устройства и проверок переноса: [docs/SITE_GENERATOR.md](docs/SITE_GENERATOR.md).

## Лицензия

Код — MIT. Локальные шрифты имеют OFL-лицензии; см. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
