# Рекомендации для Config Profile

Установщик не меняет панель. Значения ниже переносятся в неё вручную после успешного `rw-node diagnose`.

## VLESS TCP REALITY

- listen: `0.0.0.0` (ядро также может открыть dual-stack в зависимости от реализации Xray);
- port: `443`;
- network: `raw`/TCP;
- security: `reality`;
- target: `127.0.0.1:8443`;
- `serverNames`: домен именно этой ноды;
- отдельная X25519-пара и short IDs для каждой ноды.

Публичные значения печатаются после установки. Private key хранится в
`/var/lib/rw-node-installer/profile-values.txt` с mode `0600`; показать его один раз в TTY:

```bash
rw-node profile-guidance --show-private-key
```

Не копируйте общий REALITY private key на весь парк. Список чужих доменов в `serverNames` не делает маскировку лучше: локальный Caddy должен иметь сертификат для каждого фактически используемого SNI. В базовой схеме он имеет сертификат только введённого домена.

## Hysteria2

Пути внутри контейнера:

```json
{
  "certificateFile": "/etc/ssl/hysteria/fullchain.pem",
  "keyFile": "/etc/ssl/hysteria/privkey.pem"
}
```

Masquerade должен проксировать на локальный Caddy:

```json
{
  "masquerade": {
    "type": "proxy",
    "url": "https://YOUR_NODE_DOMAIN:8443",
    "rewriteHost": true,
    "insecure": false
  }
}
```

Для inbound рекомендуется sniffing с `destOverride: ["http", "tls", "quic"]`. Не храните один статический Hysteria auth в публичном профиле репозитория; учётные данные должны выпускаться панелью. Если используемая схема Remnawave/Xray управляет клиентами через `clients`, не оставляйте одновременно неоднозначный статический `users/auth`, если документация вашей версии этого явно не требует.

## DNS и fingerprint

Для IPv4+IPv6 используйте `queryStrategy: "UseIP"`, а не принудительный `UseIPv4`. AAAA-запись необязательна: без неё установка продолжается с предупреждением и IPv6-вход не используется. Если AAAA опубликована, установщик проверяет её соответствие серверу; конкретное поведение outbound определяет профиль.

Fingerprint Firefox/QQ задаётся в Host/клиентской части Remnawave и не является параметром установщика ноды.

## Секреты из прежних конфигураций

Любой REALITY private key, Hysteria auth или Node `SECRET_KEY`, однажды опубликованный в чате, issue или репозитории, следует считать раскрытым и заменить. Удаление строки из последующего commit не отзывает уже скопированный секрет.
