# Эксплуатация и восстановление

## Ежедневные проверки

```bash
rw-node status
rw-node diagnose
journalctl -u remnanode --since today
journalctl -u caddy --since today
```

У Node-контейнера включена ротация Docker JSON logs. Доступ Caddy также ротируется. Journald ограничен по размеру и сроку хранения.

## Обновление Node

Автоматическая проверка запускается timer:

```bash
systemctl list-timers rw-node-auto-update.timer
journalctl -u rw-node-auto-update.service
```

Ручная проверка использует тот же rollback:

```bash
rw-node update-node
```

Если новый digest не прошёл health-check, он записывается в `/var/lib/rw-node-installer/rejected-image` и повторно не применяется. Следующий действительно новый digest будет проверен как обычно.
Успешно развёрнутые digest записываются в root-only `/var/lib/rw-node-installer/deployed-images.log`.

`latest` — осознанное требование этой конфигурации и остаточный supply-chain риск: health-check обнаруживает падение, но не злонамеренный образ, который продолжает отвечать. Компрометация publisher/registry особенно существенна из-за host network и `NET_ADMIN`.

## Сертификат

```bash
rw-node cert-sync
systemctl list-timers rw-node-cert-sync.timer
openssl x509 -in /etc/ssl/hysteria/fullchain.pem -noout -subject -issuer -dates
```

Если выпуск не удался, проверьте A/AAAA, внешний firewall и TCP 80, затем `journalctl -u caddy -n 100`.

## Изменение allowlist

Повторно запустите установщик с новыми параметрами. Firewall применяется с трёхминутным rollback. Откройте вторую SSH-сессию и только после успешного входа введите точное `yes`; без TTY commit запрещён. Не редактируйте сгенерированный `firewall.nft` как постоянный источник: следующий reconcile заменит его.

Перед ручной работой сохраните доступ через VNC/консоль провайдера. Проверить таблицу:

```bash
rw-node firewall
```

## Перезагрузка всей VDS

После reboot systemd последовательно поднимает:

1. `rw-node-firewall.service` до сетевых демонов;
2. Docker и контейнер с `restart: always`;
3. Caddy;
4. NIC tuning;
5. persistent timers сертификата и обновлений.

Проверка после reboot: `rw-node diagnose`.

## Удаление

`rw-node uninstall` удаляет только известные проекту таблицу, units, drop-ins, каталог Node, сайт, копии сертификата и state. Сторонние nftables-таблицы не затрагиваются. По умолчанию пакеты Docker/Caddy сохраняются; `--purge-packages` удаляет их и поэтому подходит только для выделенной чистой ноды.
