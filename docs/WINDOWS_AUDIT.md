# Windows audit

**Исходный коммит:** `ab078a24621cacab289a8d3ddbb5fe38b16462b4` (origin/main, merge PR #11 `feature/world-overhaul`)
**Ветка:** `platform/windows`
**Окружение:** Windows 11 Pro x64, NVIDIA GeForce RTX 5060 Ti, 32 ГБ RAM, Godot 4.7.2 stable (winget `GodotEngine.GodotEngine`), Python 3.12, Git 2.56, Git LFS 3.8, gh 2.103.

## Что уже работает
- Импорт: `godot --headless --path . --import` — без ошибок.
- Игра запускается окном (Vulkan 1.4, Forward Mobile, RTX 5060 Ti), выход 0.
- `tests/run_tests.gd`: 1839 проверок, 0 ошибок (включая реальную карту: 205 стран, 14 779 ячеек, частичный захват, окружение/снабжение, сохранения и миграция, детерминизм).
- `tests/run_ui_tests.gd`: 47 проверок, 0 ошибок.
- `tools/validate_data.py`: OK (14 779 ячеек, 70 039 населённых пунктов).
- Симуляция на реальной карте ≈ 67 мс/день (по тесту).
- Жёстко прописанных macOS-путей (`/Users/`) в `.gd` не найдено.

## Что отсутствует
- Android-пресет экспорта (Windows-пресет добавлен).
- Задача windows-build в CI добавлена, но ещё не прогонялась в Actions.
- Export templates Godot (устанавливаются отдельно).
- Каталог `platform/windows` пуст (`.gitkeep`).

## Что требует проверки/адаптации
- Ручная проверка меню → выбор страны → карта → сохранение F5/загрузка на живом окне.
- Масштабирование UI/DPI, разрешения 1366×768 … 3840×2160, borderless/fullscreen.
- Профилирование FPS/RAM/GPU на реальном ПК.
- Совместимость сохранений Windows ↔ macOS (world_hash).

## Нельзя менять без согласования с macOS-разработчиком
Формат мира и ID ячеек, `world_hash`, формат сохранений, сетевые протоколы, публичные команды `Simulation.apply_command()`, структуру симуляции, версию Godot.

## Ошибки на Windows
- Тесты проходят. Только предупреждения о утечке RID при выходе UI-тестов (headless dummy renderer), не падение.
- `winget` не создаёт алиас `godot` без прав администратора: путь к exe — `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\`.

