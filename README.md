# rw-node-installer

Интерактивный установщик Remnawave Node для **чистой Debian 12 или 13**. Он разворачивает Node в Docker, локальный self-steal-сайт на Caddy, сертификаты для Hysteria2, постоянный nftables firewall, адаптивный сетевой тюнинг и обновление образа `remnawave/node:latest` с health-check и автоматическим откатом.

Проект рассчитан на профиль с двумя публичными inbound на одном адресе:

- VLESS TCP REALITY — `443/tcp`, target `127.0.0.1:8443`;
- Hysteria2 — `443/udp`, сертификат Caddy и proxy masquerade на локальный сайт.

Установщик не подключается к API панели и ничего в ней не создаёт. После установки он печатает значения и рекомендации, которые нужно перенести в панель вручную.

## Что именно настраивается

- официальный Docker Engine и Compose plugin;
- официальный стабильный Caddy;
- `remnawave/node:latest` в host network с `NET_ADMIN` для Node Plugins;
- уникальный сайт из `run.py`, локальные WOFF2-шрифты без Google Fonts;
- сертификат ACME HTTP-01 на Caddy и его безопасная копия в `/etc/ssl/hysteria`;
- отдельная таблица `inet rw_node_guard`, не удаляющая таблицы Remnawave Plugins;
- SSH `22/tcp` только от IP панели и списка администраторов;
- Node API `2222/tcp` только от IP панели;
- публичные `80/tcp`, `443/tcp`, `443/udp`; остальные входящие соединения молча отбрасываются;
- IPv4 и IPv6 в одном ruleset; IPv6 используется автоматически, если настроен у провайдера;
- BBR+fq при наличии в ядре, безопасные sysctl, лимиты журналов и осторожный NIC/RPS-тюнинг;
- ежедневная проверка `latest`, health-check и возврат к последнему рабочему image digest;
- security-only unattended upgrades без автоматической перезагрузки.

## Перед установкой

Нужны:

1. Чистая Debian 12/13 `amd64` или `arm64` с systemd.
2. A-запись домена на IPv4 ноды. Если опубликована AAAA-запись, IPv6 ноды обязан работать.
3. Внешние firewall/security groups провайдера должны пропускать `80/tcp`, `443/tcp`, `443/udp`, а также `22/tcp` и `2222/tcp` от соответствующих доверенных адресов.
4. `SECRET_KEY`, созданный панелью Remnawave.
5. IP панели и один или несколько IP/CIDR администратора.

Если сервер уже содержит чужой Caddy, Docker, firewall или данные в `/opt/remnanode`, сначала разберите конфликт вручную. Установщик специально ориентирован на чистую систему и отказывается продолжать при занятых портах.

## Установка

После публикации замените URL и подставьте полный commit SHA, которому доверяете. И bootstrap,
и архив загружаются из одного неизменяемого commit; имя ветки установщик намеренно не принимает:

```bash
COMMIT_SHA=0123456789abcdef0123456789abcdef01234567; apt-get update && apt-get install -y ca-certificates curl tar && curl -fsSL "https://raw.githubusercontent.com/USER/REPOSITORY/${COMMIT_SHA}/install.sh" | sudo env RW_INSTALLER_REPO=https://github.com/USER/REPOSITORY RW_INSTALLER_REF="$COMMIT_SHA" bash
```

Из локального клона:

```bash
sudo ./install.sh
```

Будут запрошены:

- домен ноды;
- `SECRET_KEY` (ввод скрыт);
- один IPv4 или IPv6 панели;
- IP/CIDR администраторов через запятую;
- необязательный email для ACME.

Неинтерактивные параметры описаны в `rw-node help`; секрет передаётся только через `RW_SECRET_KEY`. Помните, что переменная окружения root-процесса потенциально доступна средствам диагностики системы — интерактивный скрытый ввод предпочтительнее.

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
python3 run.py --audit 100 --seed repository-audit
```

GitHub Actions дополнительно запускает ShellCheck, синтаксическую проверку nftables, адаптацию Caddyfile и `docker compose config`.

## Лицензия

Код — MIT. Локальные шрифты имеют OFL-лицензии; см. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
