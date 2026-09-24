# Эксплуатация и восстановление

Во время установки APT до десяти минут ожидает завершения `apt-daily` или
`unattended-upgrades`. Lock-файлы `dpkg` не удаляются: это могло бы повредить базу
пакетов. Если штатное обновление действительно зависло дольше этого времени, сначала
разберите `systemctl status unattended-upgrades.service` и повторите установщик.

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

Если выпуск не удался, проверьте A/AAAA, внешний firewall и TCP 80, затем:

```bash
systemctl status caddy.service rw-node-firewall.service --no-pager -l
journalctl -b -u caddy.service --no-pager -n 150
rw-node cert-sync
```

Отсутствие AAAA само по себе не является ошибкой: такая нода работает только по IPv4.

## Изменение allowlist

### Обновление правил без переустановки

Начиная с 0.3.0 bootstrap поддерживает `bash install.sh --firewall-only`.
Используйте закреплённый commit в команде установки из README и добавьте
`--firewall-only` после `bash "$RW_BOOTSTRAP_FILE"`. Запускайте из root-shell.
Это обновляет файлы установщика и только управляемый firewall, используя
сохранённые IP панели, администраторов и порт API. Повторный ввод SECRET_KEY,
APT, скачивание Node image, изменение Config Profile и перезапуск контейнера
не выполняются. Для повторного применения уже установленной версии:

```bash
rw-node update-firewall
```

Откройте вторую SSH-сессию и подтвердите `yes` в течение 180 секунд.
Без подтверждения действующие правила откатываются. После подтверждения
правила сохранены для перезагрузки всей VDS.

Внешние TCP SYN/connect-пробы к запрещённым портам получают RST (`closed`),
включая SSH и API для IP вне whitelist. Неразрешённый UDP и INVALID-пакеты
остаются DROP. Это не скрывает существование сервера и не гарантирует
обход DPI/ТСПУ. Таблицы Node Plugins могут дополнительно фильтровать трафик.
Для проверки с машины вне обоих whitelist:

```bash
nmap -sT -Pn -n --reason -p 22,80,443,2222,8443,45678 NODE_IP
```

Если API перенесён вручную, замените 2222 его сохранённым портом. Пробы с
самой ноды или с доверенного IP дадут другой результат. TCP/UDP 443 остаются
публичными: REALITY target, SNI и Hysteria masquerade настраиваются в панели.
Для Hysteria используйте вывод `rw-node profile-guidance`, чтобы обычный
HTTP/3-запрос получал тот же сайт через proxy masquerade. Обновление firewall
не исправляет профиль в панели автоматически и не меняет настройки клиентов.

### Изменение адресов

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
