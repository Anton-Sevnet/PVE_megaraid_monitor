#!/bin/bash

echo "=== Установка RAID Monitor для Proxmox VE ==="
echo

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: Запустите скрипт от пользователя root"
    exit 1
fi

# Установка swaks
echo "Установка swaks..."
apt update
apt install -y swaks

# Создание конфигурационного файла
echo
echo "Создание примера конфигурационного файла..."
if [ ! -f "/root/raid_notification.conf" ]; then
    cp /root/raid_notification.conf.example /root/raid_notification.conf
    echo "Создан файл /root/raid_notification.conf"
    echo "Отредактируйте его, указав ваши настройки email"
else
    echo "Файл /root/raid_notification.conf уже существует"
fi

# Настройка прав доступа
chmod 600 /root/raid_notification.conf

# Тестирование storcli
echo
echo "Проверка storcli..."
if command -v storcli >/dev/null 2>&1; then
    echo "storcli найден: $(which storcli)"
    storcli /c0 show | head -5
else
    echo "ОШИБКА: storcli не найден!"
    echo "Установите утилиту storcli для вашего RAID контроллера"
    exit 1
fi

# Тестирование скрипта
echo
echo "Тестирование скрипта мониторинга..."
if [ -f "/root/raid_monitor.sh" ]; then
    echo "Запуск тестовой проверки..."
    /root/raid_monitor.sh
else
    echo "ОШИБКА: Файл /root/raid_monitor.sh не найден!"
    echo "Скопируйте содержимое скрипта в этот файл"
    exit 1
fi

echo
echo "=== Установка завершена ==="
echo
echo "Для автоматического запуска добавьте в crontab:"
echo "crontab -e"
echo "*/5 * * * * /root/raid_monitor.sh"
echo
echo "Логи будут сохраняться в /var/log/raid_monitor.log"
