# Windows handoff (2026-11-16)

**Сделано:** клон `ab078a2`, ветка `platform/windows` (PR #12), Godot 4.7.2, все тесты и CI зелёные, `export_presets.cfg`, Windows x64 EXE (локально и в CI, артефакт `IRON-DOMINION-WINDOWS-X64`), аудит, отчёт, бенчмарк.

**Окружение:** Godot — `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_*\`; templates — `%APPDATA%\Godot\export_templates\4.7.2.stable`; Python — `%LOCALAPPDATA%\Programs\Python\Python312`.

**Следующие шаги:**
1. Ручная проверка реального мира в окне: выбор страны, захват ячеек, F5/загрузка.
2. Разрешения 1366×768…3840×2160, DPI, fullscreen/borderless.
3. Профилирование: ~50 FPS камеры при 1085 draw calls на RTX 5060 Ti.
4. Совместимость сохранений и world_hash Windows ↔ macOS.
5. Проверка скачанного артефакта CI на чистой Windows.
6. Android (после согласованной готовности desktop).
