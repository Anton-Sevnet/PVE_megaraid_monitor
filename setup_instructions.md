# PVE MegaRAID Monitor

Скрипт для мониторинга состояния LSI MegaRAID контроллера в Proxmox VE с отправкой уведомлений по email.

## Возможности

- ✅ Мониторинг состояния RAID контроллера
- ✅ Проверка виртуальных и физических дисков
- ✅ Мониторинг CacheVault (конденсатор)
- ✅ Проверка температуры и ошибок SMART
- ✅ Умная система уведомлений (избегает спама)
- ✅ Поддержка Yandex SMTP с правильным кодированием UTF-8
- ✅ Интеграция с настройками PVE
- ✅ Режим отладки для тестирования

## Установка

1. Скопируйте файлы на сервер PVE
2. Сделайте скрипт исполняемым:
   ```bash
   chmod +x raid_monitor.sh
   chmod +x setup_raid_monitor.sh
   ```

3. Запустите установку:
   ```bash
   ./setup_raid_monitor.sh
   ```

## Настройка

### Вариант 1: Использование настроек PVE
Скрипт автоматически использует настройки из `/etc/pve/notifications.cfg`

### Вариант 2: Собственный конфигурационный файл
Создайте файл `/root/raid_notification.conf`:
```bash
SMTP_SERVER="smtp.yandex.ru"
SMTP_PORT="587"
SMTP_USER="your-email@yandex.ru"
SMTP_PASS="your-password"
FROM_EMAIL="your-email@yandex.ru"
TO_EMAIL="admin@yourdomain.com"
ADDITIONAL_RECIPIENTS="admin2@yourdomain.com,admin3@yourdomain.com"
```

## Использование

### Обычный запуск
```bash
./raid_monitor.sh
```

### Режим отладки
```bash
./raid_monitor.sh debug
```

### Настройка cron
```bash
# Проверка каждые 15 минут
*/15 * * * * /usr/scripts/raid_monitor.sh >> /var/log/raid_monitor.log 2>&1
```

## Логика уведомлений

- **Первое уведомление**: Отправляется сразу при обнаружении проблем
- **Повторные уведомления**: Только если состояние изменилось или прошло 24 часа
- **Уведомления о восстановлении**: Отправляются при устранении проблем в течение 24 часов
- **Режим отладки**: Отправляет уведомления при любом состоянии

## Поддерживаемые провайдеры SMTP

- ✅ Yandex (smtp.yandex.ru:587 с STARTTLS)
- ✅ Gmail (smtp.gmail.com:587 с STARTTLS)
- ✅ Другие SMTP серверы с поддержкой STARTTLS

## Требования

- Proxmox VE
- LSI MegaRAID контроллер
- Утилита `storcli`
- Утилита `swaks` для отправки email
- Bash 4.0+

## Файлы

- `raid_monitor.sh` - основной скрипт мониторинга
- `setup_raid_monitor.sh` - скрипт установки
- `raid_notification.conf.example` - пример конфигурации
- `raid_monitor_state.conf.example` - пример файла состояния

## Лицензия

MIT License
