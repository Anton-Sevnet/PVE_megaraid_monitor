#!/bin/bash

# Конфигурационный файл
CONFIG_FILE="/root/raid_notification.conf"

# Файл для отслеживания состояния ошибок
STATE_FILE="/usr/scripts/raid_monitor_state.conf"

# Параметр debug (передается как первый аргумент)
DEBUG_MODE=false
if [ "$1" = "debug" ]; then
    DEBUG_MODE=true
    echo "Режим DEBUG включен - будут отправляться уведомления даже при нормальном состоянии"
fi

# Функция для чтения конфигурации из файла
read_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        # Проверяем, что все необходимые параметры заданы
        if [ -n "$SMTP_SERVER" ] && [ -n "$SMTP_PORT" ] && [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ] && [ -n "$FROM_EMAIL" ] && [ -n "$TO_EMAIL" ]; then
            echo "Используется конфигурация из файла $CONFIG_FILE"
            # Инициализируем ADDITIONAL_RECIPIENTS если не задан
            if [ -z "$ADDITIONAL_RECIPIENTS" ]; then
                ADDITIONAL_RECIPIENTS=""
            fi
            return 0
        else
            echo "В файле $CONFIG_FILE не хватает параметров, используем настройки PVE"
            return 1
        fi
    else
        echo "Файл $CONFIG_FILE не найден, используем настройки PVE"
        return 1
    fi
}

# Функция для чтения настроек из PVE
read_pve_config() {
    echo "Читаем настройки из PVE target 'mail'..."
    
    # Читаем настройки из /etc/pve/notifications.cfg
    SMTP_SERVER=$(grep -A 10 "smtp: mail" /etc/pve/notifications.cfg | grep "server" | awk '{print $2}')
    SMTP_PORT=$(grep -A 10 "smtp: mail" /etc/pve/notifications.cfg | grep "port" | awk '{print $2}')
    SMTP_USER=$(grep -A 10 "smtp: mail" /etc/pve/notifications.cfg | grep "username" | awk '{print $2}')
    FROM_EMAIL=$(grep -A 10 "smtp: mail" /etc/pve/notifications.cfg | grep "from-address" | awk '{print $2}')
    
    # Читаем пароль из приватного файла
    SMTP_PASS=$(grep -A 5 "smtp: mail" /etc/pve/priv/notifications.cfg | grep "password" | awk '{print $2}')
    
    # Читаем основного получателя (поле "mailto-user" - получаем email пользователя из PVE)
    local mailto_user=$(grep -A 10 "smtp: mail" /etc/pve/notifications.cfg | grep "mailto-user" | awk '{print $2}')
    TO_EMAIL=""
    if [ -n "$mailto_user" ]; then
        # Получаем email пользователя из PVE (проверяем несколько возможных мест)
        local user_email=""
        
        # Пробуем получить из /etc/pve/user.cfg
        if [ -f "/etc/pve/user.cfg" ]; then
            user_email=$(grep "^user:$mailto_user:" /etc/pve/user.cfg | cut -d':' -f7)
        fi
        
        # Если не нашли, пробуем получить из /etc/pve/priv/user.cfg
        if [ -z "$user_email" ] && [ -f "/etc/pve/priv/user.cfg" ]; then
            user_email=$(grep "^user:$mailto_user:" /etc/pve/priv/user.cfg | cut -d':' -f7)
        fi
        
        # Если email найден, устанавливаем как основного получателя
        if [ -n "$user_email" ]; then
            TO_EMAIL="$user_email"
        else
            echo "Предупреждение: не удалось найти email для пользователя $mailto_user, используем значение по умолчанию"
            TO_EMAIL="admin@example.com"
        fi
    else
        TO_EMAIL="admin@example.com"
    fi
    
    # Читаем дополнительных получателей (поле "mailto" может быть несколько строк)
    ADDITIONAL_RECIPIENTS=$(grep -A 10 "smtp: mail" /etc/pve/notifications.cfg | grep "mailto " | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
    
    echo "Настройки PVE:"
    echo "  SMTP Server: $SMTP_SERVER"
    echo "  SMTP Port: $SMTP_PORT"
    echo "  SMTP User: $SMTP_USER"
    echo "  From Email: $FROM_EMAIL"
    echo "  Main Recipient (mailto-user field): $TO_EMAIL"
    if [ -n "$ADDITIONAL_RECIPIENTS" ]; then
        echo "  Additional Recipients (mailto field): $ADDITIONAL_RECIPIENTS"
    fi
}

# Функция для сохранения состояния ошибок
save_error_state() {
    local issues="$1"
    local timestamp=$(date +%s)
    
    # Создаем хеш от списка проблем для сравнения
    local issues_hash=$(echo "$issues" | sort | md5sum | cut -d' ' -f1)
    
    echo "DEBUG: save_error_state - сохраняем хеш: $issues_hash"
    echo "DEBUG: save_error_state - проблемы: '$issues'"
    
    # Сохраняем список ошибок в файл (экранируем кавычки)
    local escaped_issues=$(echo "$issues" | sed 's/"/\\"/g')
    
    cat > "$STATE_FILE" << EOF
# Состояние ошибок RAID контроллера
LAST_ERRORS_HASH="$issues_hash"
LAST_ERRORS_COUNT=$(echo "$issues" | wc -l)
LAST_ERRORS_TIME="$timestamp"
LAST_NOTIFICATION_TIME="0"
LAST_ERRORS_LIST="$escaped_issues"
EOF
    
    echo "Сохранено состояние ошибок: $issues_hash"
}

# Функция для загрузки состояния ошибок
load_error_state() {
    if [ -f "$STATE_FILE" ]; then
        echo "DEBUG: load_error_state - загружаем состояние из $STATE_FILE"
        source "$STATE_FILE"
        echo "DEBUG: load_error_state - загружено: HASH=$LAST_ERRORS_HASH, TIME=$LAST_NOTIFICATION_TIME"
        return 0
    else
        echo "DEBUG: load_error_state - файл $STATE_FILE не найден, создаем пустое состояние"
        # Если файл не существует, создаем пустое состояние
        LAST_ERRORS_HASH=""
        LAST_ERRORS_COUNT="0"
        LAST_ERRORS_TIME="0"
        LAST_NOTIFICATION_TIME="0"
        LAST_ERRORS_LIST=""
        return 1
    fi
}

# Функция для проверки необходимости отправки уведомления
should_send_notification() {
    local current_issues="$1"
    local current_hash=$(echo "$current_issues" | sort | md5sum | cut -d' ' -f1)
    local current_time=$(date +%s)
    local day_in_seconds=86400  # 24 часа
    
    echo "DEBUG: should_send_notification вызвана с проблемами: '$current_issues'"
    echo "DEBUG: Текущий хеш: $current_hash"
    
    echo "DEBUG: Последний хеш: $LAST_ERRORS_HASH"
    echo "DEBUG: Последнее время уведомления: $LAST_NOTIFICATION_TIME"
    echo "DEBUG: Текущее время: $current_time"
    
    # Если это режим DEBUG, всегда отправляем
    if [ "$DEBUG_MODE" = true ]; then
        echo "DEBUG режим: отправляем уведомление"
        return 0
    fi
    
    # Если ошибок нет, но раньше были - проверяем, была ли проблема в течение 24 часов
    if [ -z "$current_issues" ] && [ "$LAST_ERRORS_COUNT" -gt 0 ]; then
        # Проверяем, была ли проблема в течение последних 24 часов
        local time_since_errors=$((current_time - LAST_ERRORS_TIME))
        if [ "$time_since_errors" -le "$day_in_seconds" ]; then
            # Дополнительная проверка: есть ли реально устраненные проблемы
            analysis=$(analyze_error_changes "$current_issues" "$LAST_ERRORS_LIST")
            resolved_count=$(echo "$analysis" | grep "RESOLVED_COUNT:" | cut -d: -f2)
            resolved_count=${resolved_count:-0}
            
            if [ "$resolved_count" -gt 0 ]; then
                echo "Ошибки устранены в течение 24 часов: отправляем уведомление о восстановлении"
                return 0
            else
                echo "Нет реально устраненных ошибок: не отправляем уведомление о восстановлении"
                return 1
            fi
        else
            echo "Ошибки были давно (более 24 часов назад): не отправляем уведомление о восстановлении"
            return 1
        fi
    fi
    
    # Если есть ошибки
    if [ -n "$current_issues" ]; then
        echo "DEBUG: Есть ошибки, проверяем хеш..."
        # Если хеш ошибок изменился - отправляем уведомление
        if [ "$current_hash" != "$LAST_ERRORS_HASH" ]; then
            echo "DEBUG: Хеш изменился ($current_hash != $LAST_ERRORS_HASH)"
            echo "Состояние ошибок изменилось: отправляем уведомление"
            return 0
        fi
        
        echo "DEBUG: Хеш не изменился, проверяем время..."
        # Если хеш не изменился, но прошло больше 24 часов с последнего уведомления
        local time_since_notification=$((current_time - LAST_NOTIFICATION_TIME))
        echo "DEBUG: Время с последнего уведомления: $time_since_notification секунд"
        if [ "$LAST_NOTIFICATION_TIME" -gt 0 ] && [ "$time_since_notification" -ge "$day_in_seconds" ]; then
            echo "DEBUG: Прошло больше 24 часов"
            echo "Прошло 24 часа с последнего уведомления: отправляем повторное"
            return 0
        elif [ "$LAST_NOTIFICATION_TIME" -eq 0 ]; then
            echo "DEBUG: Первое уведомление"
            echo "Первое уведомление: отправляем"
            return 0
        fi
        
        echo "DEBUG: Состояние не изменилось и прошло менее 24 часов"
        echo "Состояние не изменилось и прошло менее 24 часов: пропускаем уведомление"
        return 1
    fi
    
    # Если ошибок нет и раньше их не было, или они были давно
    echo "Ошибок нет: не отправляем уведомление"
    return 1
}

# Функция для анализа изменений в ошибках
analyze_error_changes() {
    local current_issues="$1"
    local previous_issues="$2"
    
    # Создаем временные файлы для сравнения
    local current_file=$(mktemp)
    local previous_file=$(mktemp)
    
    echo "$current_issues" | sort > "$current_file"
    echo "$previous_issues" | sort > "$previous_file"
    
    # Находим устраненные проблемы
    local resolved_issues=$(comm -23 "$previous_file" "$current_file")
    
    # Находим новые проблемы
    local new_issues=$(comm -13 "$previous_file" "$current_file")
    
    # Подсчитываем количество
    local resolved_count=$(echo "$resolved_issues" | grep -c . || echo "0")
    local new_count=$(echo "$new_issues" | grep -c . || echo "0")
    local current_count=$(echo "$current_issues" | grep -c . || echo "0")
    
    # Определяем уровень критичности текущих ошибок
    local current_critical=$(echo "$current_issues" | grep -i -E "(Failed|Critical|Error|Degraded)" | wc -l)
    local current_warnings=$(echo "$current_issues" | grep -i -E "(Warning|High|Temperature)" | wc -l)
    
    # Очищаем временные файлы
    rm -f "$current_file" "$previous_file"
    
    # Возвращаем результат
    echo "RESOLVED_COUNT:$resolved_count"
    echo "NEW_COUNT:$new_count"
    echo "CURRENT_COUNT:$current_count"
    echo "CURRENT_CRITICAL:$current_critical"
    echo "CURRENT_WARNINGS:$current_warnings"
    echo "RESOLVED_ISSUES:$resolved_issues"
    echo "NEW_ISSUES:$new_issues"
}

# Функция для обновления времени последнего уведомления
update_notification_time() {
    local current_time=$(date +%s)
    
    echo "DEBUG: update_notification_time - обновляем время на $current_time"
    
    if [ -f "$STATE_FILE" ]; then
        # Загружаем текущее состояние
        source "$STATE_FILE"
        
        # Перезаписываем файл с обновленным временем
        cat > "$STATE_FILE" << EOF
# Состояние ошибок RAID контроллера
LAST_ERRORS_HASH="$LAST_ERRORS_HASH"
LAST_ERRORS_COUNT="$LAST_ERRORS_COUNT"
LAST_ERRORS_TIME="$LAST_ERRORS_TIME"
LAST_NOTIFICATION_TIME="$current_time"
LAST_ERRORS_LIST="$LAST_ERRORS_LIST"
EOF
        echo "DEBUG: update_notification_time - время обновлено в файле $STATE_FILE"
    else
        echo "DEBUG: update_notification_time - файл $STATE_FILE не найден"
    fi
}

# Функция для объединения получателей
get_all_recipients() {
    local recipients="$TO_EMAIL"
    
    echo "DEBUG: get_all_recipients - Main Recipient (mailto-user field): '$TO_EMAIL'" >&2
    echo "DEBUG: get_all_recipients - Additional Recipients (mailto field): '$ADDITIONAL_RECIPIENTS'" >&2
    
    # Добавляем дополнительных получателей из PVE или конфига
    if [ -n "$ADDITIONAL_RECIPIENTS" ]; then
        recipients="$recipients,$ADDITIONAL_RECIPIENTS"
        echo "DEBUG: get_all_recipients - объединили: '$recipients'" >&2
    fi
    
    # Убираем дубликаты и пустые значения
    local final_recipients=$(echo "$recipients" | tr ',' '\n' | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "DEBUG: get_all_recipients - финальный список: '$final_recipients'" >&2
    echo "$final_recipients"
}

# Функция для отправки email
send_email() {
    local subject="$1"
    
    # Кодируем subject в base64 для UTF-8
    local encoded_subject=$(echo -n "$subject" | base64 -w 0)
    encoded_subject="=?UTF-8?B?$encoded_subject?="
    
    local body="$2"
    local all_recipients=$(get_all_recipients)
    
    echo "Отправляем письмо..."
    echo "  Тема: $subject"
    echo "  Закодированная тема: $encoded_subject"
    echo "  Получатели: $all_recipients"
    echo "  SMTP Server: $SMTP_SERVER:$SMTP_PORT"
    
    # Добавляем небольшую задержку для избежания блокировки
    sleep 2
    
    # Определяем параметры шифрования в зависимости от провайдера
    local tls_param=""
    if [[ "$SMTP_SERVER" == *"yandex"* ]]; then
        # Yandex использует STARTTLS на порту 587
        if [ "$SMTP_PORT" = "587" ]; then
            tls_param="--tls"
        elif [ "$SMTP_PORT" = "465" ]; then
            tls_param="--tls-on-connect"
        fi
    else
        # Для других провайдеров используем стандартный STARTTLS
        tls_param="--tls"
    fi
    
    # Отправляем email с помощью swaks с полными заголовками
    if swaks --to "$all_recipients" \
             --from "$FROM_EMAIL" \
             --server "$SMTP_SERVER" \
             --port "$SMTP_PORT" \
             --auth LOGIN \
             --auth-user "$SMTP_USER" \
             --auth-password "$SMTP_PASS" \
             $tls_param \
             --header "Subject: $encoded_subject" \
             --header "Message-ID: <$(date +%s).$(hostname)@$(hostname)>" \
             --header "Date: $(date -R)" \
             --header "MIME-Version: 1.0" \
             --header "Content-Type: text/plain; charset=UTF-8" \
             --header "X-Mailer: RAID Monitor Script" \
             --header "X-Priority: 3" \
             --body "$body" \
             --silent; then
        echo "Письмо отправлено успешно"
        return 0
    else
        echo "Ошибка отправки письма"
        return 1
    fi
}

# Функция для отображения прогресса
show_progress() {
    local message="$1"
    local spinner_chars="\|/—"
    local i=0
    
    while true; do
        printf "\r%s %c" "$message" "${spinner_chars:$i:1}"
        i=$(( (i+1) % 4 ))
        sleep 0.2
    done
}

# Функция для проверки состояния контроллера
check_controller_status() {
    local issues=()
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем общее состояние контроллера... (storcli /c0 show)" >&2
    fi
    
    # Проверяем общее состояние контроллера
    local controller_status=$(storcli /c0 show | grep -i "Status" | awk '{print $3}')
    if [ "$controller_status" != "Success" ]; then
        issues+=("→ Проверяем общее состояние контроллера... НАЙДЕНА ПРОБЛЕМА: Status = '$controller_status'")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем состояние CacheVault... (storcli /c0 /cv show)" >&2
    fi
    
    # Проверяем состояние CacheVault (конденсатор)
    local cv_status=$(storcli /c0 /cv show | grep -A 10 "Cachevault_Info" | grep -E "^[A-Z0-9]" | tail -1 | awk '{print $2}')
    if [ -n "$cv_status" ] && [ "$cv_status" != "Optimal" ]; then
        issues+=("→ Проверяем состояние CacheVault... НАЙДЕНА ПРОБЛЕМА: State = '$cv_status'")
    fi
    
    # Проверяем температуру CacheVault
    local cv_temp=$(storcli /c0 /cv show | grep -A 10 "Cachevault_Info" | grep -E "^[A-Z0-9]" | tail -1 | awk '{print $3}' | sed 's/C//')
    if [ -n "$cv_temp" ] && [ "$cv_temp" -gt 50 ] 2>/dev/null; then
        issues+=("→ Проверяем состояние CacheVault... НАЙДЕНА ПРОБЛЕМА: Temp = '${cv_temp}C' (высокая)")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем состояние виртуальных дисков... (storcli /c0 /vall show)" >&2
    fi
    
    # Проверяем состояние виртуальных дисков (улучшенный метод)
    local vd_output=$(storcli /c0 /vall show 2>/dev/null)
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Полный вывод vd_output:" >&2
        echo "$vd_output" >&2
    fi
    
    # Альтернативный метод - ищем строки с дисками напрямую
    local vd_lines=$(echo "$vd_output" | grep -E "^[0-9]+/[0-9]+")
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Найденные строки с дисками:" >&2
        echo "$vd_lines" >&2
    fi
    
    # Проверяем каждый виртуальный диск
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local vd_state=$(echo "$line" | awk '{print $3}')
            local vd_id=$(echo "$line" | awk '{print $1}')
            
            if [ "$DEBUG_MODE" = true ]; then
                echo "  DEBUG: Диск $vd_id состояние = '$vd_state'" >&2
                echo "  DEBUG: Проверяем условие: '$vd_state' != 'Optl'" >&2
            fi
            
            if [ "$vd_state" != "Optl" ]; then
                if [ "$DEBUG_MODE" = true ]; then
                    echo "  DEBUG: Добавляем проблему для диска $vd_id" >&2
                fi
                issues+=("→ Виртуальный диск $vd_id в состоянии: $vd_state")
            else
                if [ "$DEBUG_MODE" = true ]; then
                    echo "  DEBUG: Диск $vd_id в нормальном состоянии" >&2
                fi
            fi
        fi
    done <<< "$vd_lines"
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем состояние физических дисков... (storcli /c0 /eall /sall show)" >&2
    fi
    
    # Проверяем состояние физических дисков (улучшенный метод)
    local pd_output=$(storcli /c0 /eall /sall show 2>/dev/null)
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Полный вывод pd_output:" >&2
        echo "$pd_output" >&2
    fi
    
    # Альтернативный метод - ищем строки с дисками напрямую
    local pd_lines=$(echo "$pd_output" | grep -E "^[0-9]+:[0-9]+")
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Найденные строки с дисками:" >&2
        echo "$pd_lines" >&2
    fi
    
    # Проверяем каждый физический диск
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local pd_state=$(echo "$line" | awk '{print $3}')
            local pd_id=$(echo "$line" | awk '{print $1}')
            
            if [ "$DEBUG_MODE" = true ]; then
                echo "  DEBUG: Диск $pd_id состояние = '$pd_state'" >&2
                echo "  DEBUG: Проверяем условие: '$pd_state' != 'Onln'" >&2
            fi
            
            if [ "$pd_state" != "Onln" ]; then
                if [ "$DEBUG_MODE" = true ]; then
                    echo "  DEBUG: Добавляем проблему для диска $pd_id" >&2
                fi
                issues+=("→ Физический диск $pd_id в состоянии: $pd_state")
            else
                if [ "$DEBUG_MODE" = true ]; then
                    echo "  DEBUG: Диск $pd_id в нормальном состоянии" >&2
                fi
            fi
        fi
    done <<< "$pd_lines"
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем физические диски на ошибки... (storcli /c0/eX/sY show smart, storcli /c0/eX/sY show phyerrorcounters)" >&2
    fi
    
    # Проверяем физические диски на ошибки (улучшенный метод)
    local physical_disks=$(echo "$pd_lines" | awk '{print $1}' | sed 's/:/ /')
    
    while read -r enclosure slot; do
        if [ -n "$enclosure" ] && [ -n "$slot" ]; then
            if [ "$DEBUG_MODE" = true ]; then
                echo "    → Проверяем диск ${enclosure}:${slot}..." >&2
            fi
            
                # Проверяем SMART статус диска
                local smart_status=$(storcli /c0/e${enclosure}/s${slot} show smart 2>/dev/null | grep -i "Drive Temperature\|SMART Alert" | head -1)
                if [ -n "$smart_status" ] && echo "$smart_status" | grep -qi "alert\|warning\|fail"; then
                    issues+=("→ Проверяем физические диски на ошибки... НАЙДЕНА ПРОБЛЕМА: Диск ${enclosure}:${slot} - проблемы SMART: '$smart_status'")
                fi
                
                # Проверяем счетчики ошибок
                local error_count=$(storcli /c0/e${enclosure}/s${slot} show phyerrorcounters 2>/dev/null | grep -E "Media Error|Other Error|Predictive Failure" | awk '{sum+=$2} END {print sum+0}')
                if [ -n "$error_count" ] && [ "$error_count" -gt 0 ]; then
                    issues+=("→ Проверяем физические диски на ошибки... НАЙДЕНА ПРОБЛЕМА: Диск ${enclosure}:${slot} - найдено $error_count ошибок")
                fi
        fi
    done <<< "$physical_disks"
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем состояние кэша... (storcli /c0 show cache)" >&2
    fi
    
    # Проверяем состояние кэша
    local cache_status=$(storcli /c0 show cache 2>/dev/null | grep -i "Status" | awk '{print $2}')
    if [ -n "$cache_status" ] && [ "$cache_status" != "OK" ]; then
        issues+=("→ Проверяем состояние кэша... НАЙДЕНА ПРОБЛЕМА: Status = '$cache_status'")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем фоновые задачи... (storcli /c0 show bgi)" >&2
    fi
    
    # Проверяем фоновые задачи
    local bgi_status=$(storcli /c0 show bgi 2>/dev/null | grep -i "Status" | awk '{print $2}')
    if [ -n "$bgi_status" ] && [ "$bgi_status" != "None" ]; then
        issues+=("→ Проверяем фоновые задачи... НАЙДЕНА ПРОБЛЕМА: Status = '$bgi_status'")
    fi
    
    # Возвращаем массив проблем
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Найдено проблем: ${#issues[@]}" >&2
        for issue in "${issues[@]}"; do
            echo "  DEBUG: Проблема: $issue" >&2
        done
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Основная логика
echo "$(date): Запуск проверки RAID контроллера"

# Читаем конфигурацию
if ! read_config_file; then
    read_pve_config
fi

# Проверяем состояние RAID контроллера
if [ "$DEBUG_MODE" = true ]; then
    echo "Проверяем состояние RAID контроллера..."
    ISSUES=$(check_controller_status)
else
    echo -n "Проверяем состояние RAID контроллера"
    # Запускаем анимацию в фоне
    show_progress "Проверяем состояние RAID контроллера" &
    progress_pid=$!
    
    # Выполняем проверку
    ISSUES=$(check_controller_status)
    
    # Останавливаем анимацию
    kill $progress_pid 2>/dev/null
    wait $progress_pid 2>/dev/null
    printf "\rПроверяем состояние RAID контроллера... ✓\n"
fi

# Загружаем предыдущее состояние ПЕРЕД проверкой уведомлений
load_error_state

# Проверяем, нужно ли отправлять уведомление
echo "DEBUG: Проверяем необходимость отправки уведомления..."
echo "DEBUG: Текущие проблемы: '$ISSUES'"

if should_send_notification "$ISSUES"; then
    echo "DEBUG: should_send_notification вернул 0 (отправлять)"
if [ -n "$ISSUES" ]; then
    # Определяем уровень критичности
        critical_issues=$(echo "$ISSUES" | grep -i -E "(Failed|Critical|Error|Degraded|Dgrd)" | wc -l)
        warning_issues=$(echo "$ISSUES" | grep -i -E "(Warning|High|Temperature|Pdgd)" | wc -l)
    
    # Отправляем email для критических проблем или в режиме debug
    if [ "$critical_issues" -gt 0 ] || [ "$DEBUG_MODE" = true ]; then
        if [ "$DEBUG_MODE" = true ]; then
            SUBJECT="DEBUG: RAID контроллер на $(hostname) - обнаружены проблемы"
            BODY="РЕЖИМ ОТЛАДКИ: Обнаружены следующие проблемы:

$ISSUES

Время: $(date)
Сервер: $(hostname)

Детальная информация:

=== 1. Состояние контроллера ===
$(storcli /c0 show 2>/dev/null)

=== 2. Состояние CacheVault ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

Это тестовое сообщение в режиме DEBUG."
        else
            SUBJECT="ВНИМАНИЕ: Проблемы с RAID контроллером на $(hostname)"
            BODY="КРИТИЧЕСКИЕ ПРОБЛЕМЫ ОБНАРУЖЕНЫ:

$ISSUES

Время: $(date)
Сервер: $(hostname)

Детальная информация:

=== 1. Состояние контроллера ===
$(storcli /c0 show 2>/dev/null)

=== 2. Состояние CacheVault ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

Требуется немедленное внимание!"
            fi
            
            if [ "$DEBUG_MODE" = true ]; then
                echo "DEBUG: Отправляем письмо с темой: '$SUBJECT'"
            fi
            send_email "$SUBJECT" "$BODY"
            # Обновляем время последнего уведомления
            echo "DEBUG: Вызываем update_notification_time после отправки письма"
            update_notification_time
        fi
    else
        # Случай восстановления - ошибки устранены в течение 24 часов
        # Анализируем изменения в ошибках
        analysis=$(analyze_error_changes "$ISSUES" "$LAST_ERRORS_LIST")
        resolved_count=$(echo "$analysis" | grep "RESOLVED_COUNT:" | cut -d: -f2)
        current_critical=$(echo "$analysis" | grep "CURRENT_CRITICAL:" | cut -d: -f2)
        current_warnings=$(echo "$analysis" | grep "CURRENT_WARNINGS:" | cut -d: -f2)
        resolved_issues=$(echo "$analysis" | grep "RESOLVED_ISSUES:" | cut -d: -f2-)
        
        # Устанавливаем значения по умолчанию для пустых переменных
        resolved_count=${resolved_count:-0}
        current_critical=${current_critical:-0}
        current_warnings=${current_warnings:-0}
        
        # Проверяем, есть ли реально устраненные проблемы (или это режим DEBUG)
        if [ "$resolved_count" -gt 0 ] || [ "$DEBUG_MODE" = true ]; then
            # Определяем тип уведомления на основе оставшихся проблем
            if [ "$current_critical" -gt 0 ]; then
                SUBJECT="ЧАСТИЧНОЕ ВОССТАНОВЛЕНИЕ: RAID контроллер на $(hostname) - ERROR $current_critical, WARNING $current_warnings"
            elif [ "$current_warnings" -gt 0 ]; then
                SUBJECT="ЧАСТИЧНОЕ ВОССТАНОВЛЕНИЕ: RAID контроллер на $(hostname) - ERROR 0, WARNING $current_warnings"
            else
                SUBJECT="ПОЛНОЕ ВОССТАНОВЛЕНИЕ: RAID контроллер на $(hostname) - ERROR 0, WARNING 0"
            fi
            
            if [ "$DEBUG_MODE" = true ]; then
                BODY="DEBUG РЕЖИМ: Устранено $resolved_count проблем с RAID контроллером.

Время: $(date)
Сервер: $(hostname)

ТЕКУЩЕЕ СОСТОЯНИЕ:
- Критические ошибки (ERROR): $current_critical
- Предупреждения (WARNING): $current_warnings

УСТРАНЕННЫЕ ПРОБЛЕМЫ:
$resolved_issues

Это тестовое сообщение в режиме DEBUG."
            else
                BODY="ВОССТАНОВЛЕНИЕ: Устранено $resolved_count проблем с RAID контроллером.

Время: $(date)
Сервер: $(hostname)

ТЕКУЩЕЕ СОСТОЯНИЕ:
- Критические ошибки (ERROR): $current_critical
- Предупреждения (WARNING): $current_warnings

УСТРАНЕННЫЕ ПРОБЛЕМЫ:
$resolved_issues"
            fi
            
            BODY="$BODY

=== 1. Состояние контроллера ===
$(storcli /c0 show 2>/dev/null)

=== 2. Состояние CacheVault ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)"
            
            if [ "$DEBUG_MODE" = true ]; then
                echo "DEBUG: Отправляем письмо о восстановлении с темой: '$SUBJECT'"
            fi
            send_email "$SUBJECT" "$BODY"
            # Обновляем время последнего уведомления
            update_notification_time
        else
            echo "Нет реально устраненных проблем: пропускаем уведомление о восстановлении"
        fi
    fi
else
    # В режиме debug отправляем email о нормальном состоянии
        if [ "$DEBUG_MODE" = true ]; then
            SUBJECT="DEBUG: RAID контроллер в норме на $(hostname)"
            BODY="РЕЖИМ ОТЛАДКИ: Все проверки RAID контроллера пройдены успешно.

Время: $(date)
Сервер: $(hostname)

=== 1. Состояние контроллера ===
$(storcli /c0 show 2>/dev/null)

=== 2. Состояние CacheVault ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

Это тестовое сообщение в режиме DEBUG."
            
        echo "DEBUG: Отправляем письмо о нормальном состоянии с темой: '$SUBJECT'"
        send_email "$SUBJECT" "$BODY"
        # Обновляем время последнего уведомления
        update_notification_time
    fi
fi

# Сохраняем текущее состояние ошибок ПОСЛЕ всех проверок
save_error_state "$ISSUES"

echo "$(date): Проверка завершена"
