#!/bin/bash

# Enhanced RAID Monitor Script
# Based on calomel.org lsi.sh script (https://calomel.org/megacli_lsi_commands.html)
# Adapted for storcli utility and modern LSI MegaRAID controllers
# Original calomel.org script by Calomel.org team
# Enhanced version by Anton-Sevnet

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

# =============================================================================
# ENHANCED FUNCTIONS BASED ON CALOMEL.ORG LSI.SH SCRIPT
# =============================================================================

# Функция для проверки состояния BBU (Battery Backup Unit) или CacheVault
# Адаптировано из calomel.org lsi.sh
# Учитывает, что в контроллере может быть либо BBU, либо CacheVault, но не оба одновременно
check_bbu_status() {
    local issues=()
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем состояние BBU/CacheVault... (storcli /c0 /cv show)" >&2
    fi
    
    # Получаем информацию о CacheVault/BBU
    local cv_output=$(storcli /c0 /cv show 2>/dev/null)
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Полный вывод CV:" >&2
        echo "$cv_output" >&2
    fi
    
    # Проверяем, есть ли вообще CacheVault/BBU в системе
    local cv_exists=$(echo "$cv_output" | grep -i "Cachevault_Info\|BBU_Info" | wc -l)
    
    if [ "$cv_exists" -eq 0 ]; then
        if [ "$DEBUG_MODE" = true ]; then
            echo "  DEBUG: CacheVault/BBU не обнаружен в системе" >&2
        fi
        # Если нет CacheVault/BBU, это не ошибка - просто нет такого компонента
        return 0
    fi
    
    # Определяем тип компонента (BBU или CacheVault)
    local component_type=""
    local component_info=""
    
    if echo "$cv_output" | grep -qi "Cachevault_Info"; then
        component_type="CacheVault"
        component_info=$(echo "$cv_output" | grep -A 10 "Cachevault_Info" | grep -E "^[A-Z0-9]" | tail -1)
    elif echo "$cv_output" | grep -qi "BBU_Info"; then
        component_type="BBU"
        component_info=$(echo "$cv_output" | grep -A 10 "BBU_Info" | grep -E "^[A-Z0-9]" | tail -1)
    fi
    
    if [ -z "$component_info" ]; then
        if [ "$DEBUG_MODE" = true ]; then
            echo "  DEBUG: Не удалось получить информацию о $component_type" >&2
        fi
        return 0
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  DEBUG: Обнаружен $component_type: $component_info" >&2
    fi
    
    # Проверяем состояние компонента
    local cv_state=$(echo "$component_info" | awk '{print $2}')
    if [ -n "$cv_state" ] && [ "$cv_state" != "Optimal" ]; then
        issues+=("→ $component_type в состоянии: $cv_state")
    fi
    
    # Проверяем температуру (только для CacheVault, у BBU может не быть температуры)
    if [ "$component_type" = "CacheVault" ]; then
        local cv_temp=$(echo "$component_info" | awk '{print $3}' | sed 's/C//')
        if [ -n "$cv_temp" ] && [ "$cv_temp" -gt 50 ] 2>/dev/null; then
            issues+=("→ $component_type высокая температура: ${cv_temp}C")
        fi
    fi
    
    # Проверяем заряд батареи (только для BBU, у CacheVault нет заряда)
    if [ "$component_type" = "BBU" ]; then
        local cv_charge=$(echo "$cv_output" | grep -i "charge" | awk '{print $NF}' | sed 's/%//')
        if [ -n "$cv_charge" ] && [ "$cv_charge" -lt 80 ] 2>/dev/null; then
            issues+=("→ $component_type низкий заряд: ${cv_charge}%")
        fi
        
        # Проверяем состояние зарядки
        local charging_status=$(echo "$cv_output" | grep -i "charging" | awk '{print $NF}')
        if [ -n "$charging_status" ] && [ "$charging_status" = "No" ]; then
            # Это не обязательно ошибка, но может быть предупреждением
            if [ "$DEBUG_MODE" = true ]; then
                echo "  DEBUG: BBU не заряжается" >&2
            fi
        fi
    fi
    
    # Проверяем состояние кэша (общее для обоих типов)
    local cache_status=$(echo "$cv_output" | grep -i "cache" | grep -i "status" | awk '{print $NF}')
    if [ -n "$cache_status" ] && [ "$cache_status" != "OK" ] && [ "$cache_status" != "Optimal" ]; then
        issues+=("→ $component_type кэш в состоянии: $cache_status")
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Функция для детальной проверки ошибок дисков
# Адаптировано из calomel.org lsi.sh
check_disk_errors() {
    local issues=()
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем ошибки дисков... (storcli /c0 /eall /sall show)" >&2
    fi
    
    # Получаем список всех физических дисков
    local pd_output=$(storcli /c0 /eall /sall show 2>/dev/null)
    local pd_lines=$(echo "$pd_output" | grep -E "^[0-9]+:[0-9]+")
    
    # Проверяем каждый диск на ошибки
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local pd_id=$(echo "$line" | awk '{print $1}')
            local pd_state=$(echo "$line" | awk '{print $3}')
            local enclosure=$(echo "$pd_id" | cut -d: -f1)
            local slot=$(echo "$pd_id" | cut -d: -f2)
            
            # Проверяем состояние диска
            if [ "$pd_state" != "Onln" ]; then
                issues+=("→ Диск $pd_id в состоянии: $pd_state")
            fi
            
            # Проверяем SMART статус
            local smart_output=$(storcli /c0/e${enclosure}/s${slot} show smart 2>/dev/null)
            if [ -n "$smart_output" ]; then
                # Проверяем на критические SMART атрибуты
                local smart_issues=$(echo "$smart_output" | grep -i -E "(fail|warning|error|critical)" | wc -l)
                if [ "$smart_issues" -gt 0 ]; then
                    issues+=("→ Диск $pd_id имеет SMART предупреждения")
                fi
            fi
            
            # Проверяем счетчики ошибок
            local error_output=$(storcli /c0/e${enclosure}/s${slot} show phyerrorcounters 2>/dev/null)
            if [ -n "$error_output" ]; then
                local media_errors=$(echo "$error_output" | grep "Media Error" | awk '{print $2}')
                local other_errors=$(echo "$error_output" | grep "Other Error" | awk '{print $2}')
                local predictive_failures=$(echo "$error_output" | grep "Predictive Failure" | awk '{print $2}')
                
                if [ -n "$media_errors" ] && [ "$media_errors" -gt 0 ]; then
                    issues+=("→ Диск $pd_id имеет $media_errors ошибок чтения/записи")
                fi
                if [ -n "$other_errors" ] && [ "$other_errors" -gt 0 ]; then
                    issues+=("→ Диск $pd_id имеет $other_errors других ошибок")
                fi
                if [ -n "$predictive_failures" ] && [ "$predictive_failures" -gt 0 ]; then
                    issues+=("→ Диск $pd_id имеет $predictive_failures предсказанных отказов")
                fi
            fi
        fi
    done <<< "$pd_lines"
    
    printf '%s\n' "${issues[@]}"
}

# Функция для проверки прогресса фоновых операций
# Адаптировано из calomel.org lsi.sh
check_background_operations() {
    local issues=()
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем фоновые операции... (storcli /c0 show bgi)" >&2
    fi
    
    # Проверяем фоновые операции
    local bgi_output=$(storcli /c0 show bgi 2>/dev/null)
    local bgi_status=$(echo "$bgi_output" | grep -i "Status" | awk '{print $2}')
    
    if [ -n "$bgi_status" ] && [ "$bgi_status" != "None" ]; then
        local bgi_type=$(echo "$bgi_output" | grep -i "Type" | awk '{print $2}')
        local bgi_progress=$(echo "$bgi_output" | grep -i "Progress" | awk '{print $2}')
        
        if [ -n "$bgi_progress" ]; then
            issues+=("→ Фоновая операция $bgi_type в процессе: $bgi_progress")
        else
            issues+=("→ Фоновая операция $bgi_type активна")
        fi
    fi
    
    # Проверяем Patrol Read
    local patrol_output=$(storcli /c0 show patrol 2>/dev/null)
    local patrol_status=$(echo "$patrol_output" | grep -i "Status" | awk '{print $2}')
    
    if [ -n "$patrol_status" ] && [ "$patrol_status" != "Stopped" ]; then
        issues+=("→ Patrol Read активен: $patrol_status")
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Функция для анализа логов контроллера
# Адаптировано из calomel.org lsi.sh
check_controller_logs() {
    local issues=()
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "  → Проверяем логи контроллера... (storcli /c0 show events)" >&2
    fi
    
    # Проверяем события контроллера
    local events_output=$(storcli /c0 show events 2>/dev/null)
    local recent_errors=$(echo "$events_output" | grep -i -E "(error|fail|critical|warning)" | head -5)
    
    if [ -n "$recent_errors" ]; then
        issues+=("→ Найдены недавние события в логах контроллера")
        # Добавляем детали первых нескольких ошибок
        while IFS= read -r error_line; do
            if [ -n "$error_line" ]; then
                issues+=("  - $error_line")
            fi
        done <<< "$recent_errors"
    fi
    
    # Проверяем аварийные сигналы
    local alarm_output=$(storcli /c0 show alarm 2>/dev/null)
    local alarm_status=$(echo "$alarm_output" | grep -i "Status" | awk '{print $2}')
    
    if [ -n "$alarm_status" ] && [ "$alarm_status" != "Off" ]; then
        issues+=("→ Аварийный сигнал контроллера: $alarm_status")
    fi
    
    printf '%s\n' "${issues[@]}"
}

# Улучшенная функция для проверки состояния контроллера
# Объединяет все проверки на основе calomel.org lsi.sh
check_controller_status() {
    local issues=()
    
    if [ "$DEBUG_MODE" = true ]; then
        echo "Проверяем состояние RAID контроллера (Enhanced version)..." >&2
    fi
    
    # 1. Проверяем общее состояние контроллера
    local controller_status=$(storcli /c0 show | grep -i "Status" | awk '{print $3}')
    if [ "$controller_status" != "Success" ]; then
        issues+=("→ Контроллер в состоянии: $controller_status")
    fi
    
    # 2. Проверяем состояние виртуальных дисков
    local vd_output=$(storcli /c0 /vall show 2>/dev/null)
    local vd_lines=$(echo "$vd_output" | grep -E "^[0-9]+/[0-9]+")
    
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local vd_state=$(echo "$line" | awk '{print $3}')
            local vd_id=$(echo "$line" | awk '{print $1}')
            
            if [ "$vd_state" != "Optl" ]; then
                issues+=("→ Виртуальный диск $vd_id в состоянии: $vd_state")
            fi
        fi
    done <<< "$vd_lines"
    
    # 3. Проверяем BBU/CacheVault (новая функция)
    local bbu_issues=$(check_bbu_status)
    if [ -n "$bbu_issues" ]; then
        issues+=("$bbu_issues")
    fi
    
    # 4. Проверяем ошибки дисков (улучшенная функция)
    local disk_issues=$(check_disk_errors)
    if [ -n "$disk_issues" ]; then
        issues+=("$disk_issues")
    fi
    
    # 5. Проверяем фоновые операции (новая функция)
    local bg_issues=$(check_background_operations)
    if [ -n "$bg_issues" ]; then
        issues+=("$bg_issues")
    fi
    
    # 6. Проверяем логи контроллера (новая функция)
    local log_issues=$(check_controller_logs)
    if [ -n "$log_issues" ]; then
        issues+=("$log_issues")
    fi
    
    # 7. Проверяем состояние кэша
    local cache_status=$(storcli /c0 show cache 2>/dev/null | grep -i "Status" | awk '{print $2}')
    if [ -n "$cache_status" ] && [ "$cache_status" != "OK" ]; then
        issues+=("→ Кэш контроллера в состоянии: $cache_status")
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
echo "$(date): Запуск проверки RAID контроллера (Enhanced version)"

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

=== 2. Состояние CacheVault/BBU ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

=== 5. Фоновые операции ===
$(storcli /c0 show bgi 2>/dev/null)

=== 6. События контроллера ===
$(storcli /c0 show events 2>/dev/null)

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

=== 2. Состояние CacheVault/BBU ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

=== 5. Фоновые операции ===
$(storcli /c0 show bgi 2>/dev/null)

=== 6. События контроллера ===
$(storcli /c0 show events 2>/dev/null)

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

=== 2. Состояние CacheVault/BBU ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

=== 5. Фоновые операции ===
$(storcli /c0 show bgi 2>/dev/null)

=== 6. События контроллера ===
$(storcli /c0 show events 2>/dev/null)"
            
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

=== 2. Состояние CacheVault/BBU ===
$(storcli /c0 /cv show 2>/dev/null)

=== 3. Состояние виртуальных дисков ===
$(storcli /c0 /vall show 2>/dev/null)

=== 4. Состояние физических дисков ===
$(storcli /c0 /eall /sall show 2>/dev/null)

=== 5. Фоновые операции ===
$(storcli /c0 show bgi 2>/dev/null)

=== 6. События контроллера ===
$(storcli /c0 show events 2>/dev/null)

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
