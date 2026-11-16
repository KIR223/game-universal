# Windows handoff (2026-11-16)

**Сделано:** клон `ab078a2`, ветка `platform/windows` (PR #12), Godot 4.7.2, все тесты и CI зелёные, `export_presets.cfg`, Windows x64 EXE (локально и в CI, артефакт `IRON-DOMINION-WINDOWS-X64`), аудит, отчёт, бенчмарк.

**Окружение:** Godot — `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\`; templates — `%APPDATA%\Godot\export_templates\4.7.2.stable`; Python — `%LOCALAPPDATA%\Programs\Python\Python312`.

**Следующие шаги:**
1. Захват ячеек вручную в окне, fullscreen/borderless, ввод мышью и клавиатурой.
2. Настоящий 4K и DPI-масштаб (окно ОС ограничило 4K до 1924×1061), fullscreen/borderless.
3. Профилирование: ~50 FPS камеры при 1085 draw calls на RTX 5060 Ti.
4. Совместимость сохранений и world_hash Windows ↔ macOS.
5. Проверка скачанного артефакта CI на чистой Windows.
6. Android (после согласованной готовности desktop).

## Обновление (2026-11-17)
Сделано: PR #13 (FPS отрисовки 18.5→5.8 мс на дальнем плане), #14 (F11, borderless, разрешения), #15 (тест войны через команды + кросс-платформенные эталоны checksum, совпали на macOS/Linux/Windows в CI).
Осталось: ручной ввод мышью/клавиатурой, настоящий 4K и DPI, проверка скачанного артефакта CI на чистой Windows, мультиплеер Windows ↔ macOS (сеть), Android.

