# Инструкции для публикации в GitHub

## Шаг 1: Создание репозитория на GitHub

1. Зайдите на [github.com](https://github.com)
2. Нажмите зеленую кнопку "New" или "+" → "New repository"
3. Заполните поля:
   - **Repository name**: `PVE_megaraid_monitor`
   - **Description**: `Скрипт для мониторинга LSI MegaRAID контроллера в Proxmox VE с отправкой уведомлений`
   - **Visibility**: Public (или Private, если хотите)
   - **НЕ** ставьте галочки на "Add a README file", "Add .gitignore", "Choose a license" (у нас уже есть файлы)
4. Нажмите "Create repository"

## Шаг 2: Инициализация git в локальной папке

Откройте PowerShell или командную строку в папке проекта и выполните:

```powershell
# Инициализация git
git init

# Добавление всех файлов
git add .

# Первый коммит
git commit -m "Initial commit: PVE MegaRAID Monitor script"

# Добавление удаленного репозитория (замените YOUR_USERNAME на ваш GitHub username)
git remote add origin https://github.com/YOUR_USERNAME/PVE_megaraid_monitor.git

# Переименование основной ветки в main (если нужно)
git branch -M main

# Отправка в GitHub
git push -u origin main
```

## Шаг 3: Альтернативный способ через GitHub CLI

Если у вас установлен GitHub CLI:

```powershell
# Создание репозитория и публикация одной командой
gh repo create PVE_megaraid_monitor --public --source=. --remote=origin --push
```

## Шаг 4: Проверка

После выполнения команд:
1. Обновите страницу репозитория на GitHub
2. Убедитесь, что все файлы загружены
3. Проверьте, что README.md отображается корректно

## Возможные проблемы и решения

### Проблема с кодировкой пути
Если возникают проблемы с кириллицей в пути, попробуйте:
```powershell
# Перейти в папку через короткий путь
cd "G:\Проекты Cursor\Скрипт для проверки LSI MegaRaid и отправки уведомлений через PVE Notification"
```

### Проблема с аутентификацией
Если GitHub требует аутентификацию:
1. Используйте Personal Access Token вместо пароля
2. Или настройте SSH ключи

### Проблема с большими файлами
Если есть большие файлы логов, убедитесь, что они в .gitignore

## Файлы, которые будут опубликованы

✅ **Будут включены:**
- `raid_monitor.sh` - основной скрипт
- `setup_raid_monitor.sh` - скрипт установки
- `README.md` - документация
- `setup_instructions.md` - инструкции по установке
- `raid_notification.conf.example` - пример конфигурации
- `raid_monitor_state.conf.example` - пример файла состояния
- `USAGE.md` - инструкции по использованию
- `.gitignore` - исключения для git

❌ **Будут исключены:**
- `*.log` - файлы логов
- `raid_notification.conf` - конфигурация с паролями
- `raid_monitor_state.conf` - файл состояния
- `*.ppk` - SSH ключи
- `test_*.sh` - тестовые файлы
