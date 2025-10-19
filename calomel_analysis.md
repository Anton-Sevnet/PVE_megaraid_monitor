# Анализ функций calomel.org lsi.sh для адаптации под storcli

## Ключевые функции из lsi.sh, которые нужно адаптировать:

### 1. **Проверка состояния виртуальных дисков (status)**
**MegaCLI команды:**
```bash
MegaCli -LDInfo -Lall -aALL -NoLog
MegaCli -AdpPR -Info -aALL -NoLog  
MegaCli -LDCC -ShowProg -LALL -aALL -NoLog
```

**Адаптация под storcli:**
```bash
storcli /c0 /vall show
storcli /c0 show patrol
storcli /c0 show bgi
```

### 2. **Проверка состояния физических дисков (drives)**
**MegaCLI команды:**
```bash
MegaCli -PDlist -aALL -NoLog | egrep 'Slot|state'
```

**Адаптация под storcli:**
```bash
storcli /c0 /eall /sall show
```

### 3. **Проверка ошибок дисков (errors)**
**MegaCLI команды:**
```bash
MegaCli -PDlist -aALL -NoLog | egrep -i 'error|fail|slot' | egrep -v ' 0'
```

**Адаптация под storcli:**
```bash
storcli /c0 /eall /sall show | grep -i 'error\|fail'
storcli /c0/eX/sY show smart
storcli /c0/eX/sY show phyerrorcounters
```

### 4. **Проверка BBU (Battery Backup Unit)**
**MegaCLI команды:**
```bash
MegaCli -AdpBbuCmd -GetBbuStatus -a0 -NoLog
```

**Адаптация под storcli:**
```bash
storcli /c0 /cv show
```

### 5. **Проверка прогресса rebuild (progress)**
**MegaCLI команды:**
```bash
MegaCli -LDCC -ShowProg -LALL -aALL -NoLog
```

**Адаптация под storcli:**
```bash
storcli /c0 show bgi
```

### 6. **Логи контроллера (logs)**
**MegaCLI команды:**
```bash
MegaCli -AdpEventLog -GetEvents -f lsi.log -aALL -NoLog
```

**Адаптация под storcli:**
```bash
storcli /c0 show events
storcli /c0 show alarm
```

### 7. **Идентификация диска (ident)**
**MegaCLI команды:**
```bash
MegaCli -PdLocate -start -physdrv[enclosure:slot] -a0 -NoLog
```

**Адаптация под storcli:**
```bash
storcli /c0/eX/sY start locate
storcli /c0/eX/sY stop locate
```

## Критические улучшения для текущего скрипта:

### 1. **Более точная детекция состояний**
- Использовать конкретные статусы вместо поиска по ключевым словам
- Добавить проверку всех возможных состояний дисков
- Улучшить парсинг вывода storcli

### 2. **Мониторинг BBU**
- Проверка состояния батареи (критично для производительности)
- Мониторинг процесса переобучения батареи
- Предупреждения о проблемах с BBU

### 3. **Детальная диагностика ошибок**
- Анализ SMART атрибутов
- Подсчет ошибок чтения/записи
- Мониторинг температуры дисков

### 4. **Мониторинг фоновых операций**
- Проверка прогресса rebuild
- Мониторинг patrol read
- Отслеживание initialization

### 5. **Анализ логов**
- Парсинг событий контроллера
- Анализ аварийных сигналов
- История ошибок
