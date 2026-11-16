# Порядок слияния PR (Windows / Android)

Состояние на 2026-11-17, `origin/main` = `ab078a2`. Все PR открыты, ни один не влит.
Готовая проверенная комбинация всех веток — ветка `integration/windows-android` (не PR, для сверки).

## Порядок и зависимости

| # | Ветка | Что | Зависит от | Общие файлы |
|---|---|---|---|---|
| 12 | `platform/windows` | `export_presets.cfg` (Windows), CI-сборка EXE, аудит и отчёты | main | `.github/workflows/ci.yml`, `.gitignore` |
| 13 | `feature/windows-draw-perf` | отрисовка городов в 3 раза быстрее (рендер) | main | `earth_map_view.gd` |
| 14 | `feature/windows-display` | F11, borderless, разрешения | main | `main.gd`, `run_ui_tests.gd` |
| 15 | `feature/windows-war-flow-test` | сквозной тест войны + эталонные `checksum()` | main | `run_tests.gd` |
| 20 | `feature/peace-treaties` | договор с аннексией (`legal[]`) | main | `simulation.gd`, `main.gd`, `run_tests.gd` |
| 16 | `platform/android` | Android-пресеты, ETC2/ASTC, Compatibility на Android | #12 | `project.godot`, `export_presets.cfg` |
| 17 | `feature/android-touch` | масштаб по DPI, долгое нажатие, прокрутка меню | #16 | `main.gd`, `map_view.gd` |
| 18 | `feature/android-autosave` | автосохранение при сворачивании | #17 | `main.gd`, `save_system.gd` |
| 19 | `feature/android-ci` | сборка APK в CI | #16 | `ci.yml` |

#16–#19 — стек: каждый PR нацелен на предыдущую ветку. Сливать по порядку и после каждого слияния менять base следующего на `main` (GitHub делает это сам при удалении ветки).

## Реальные конфликты (проверено слиянием в одноразовой ветке)
1. **#20 после #15** — `tests/run_tests.gd`: оба PR дописывают функции в конец файла. Решение: оставить обе части.
2. **#17 после #14** — `main.gd` (`_ready`: настройки окна и масштаб по DPI стоят рядом, нужны обе строки), `tests/run_ui_tests.gd` (оба блока проверок), `docs/ANDROID.md` (два раздела).
3. #18 и #19 конфликтов не дают после #17.
Остальные пары сливаются без конфликтов.

## Проверка комбинации (`integration/windows-android`)
- Основные тесты: **1879 passed, 0 failed**; UI: **64 passed, 0 failed**; `validate_data.py` и `check_licenses.py` — OK.
- Эталонные `checksum()` (`idle30=2965233151`, `war40=3973190776`) не изменились ни одним из PR; на macOS/Linux/Windows в CI совпадали.
- Экспорт: Windows EXE 116.2 МБ, Android debug APK 37.8 МБ, подпись APK валидна.
- Ранее вручную: Windows EXE (локальный и из CI) проходит путь до выбора страны на реальной карте; Android APK из CI открывает реальный мир в эмуляторе.

## Что решать владельцу
- **Общие файлы**: `project.godot` (#16: `import_etc2_astc=true` нужен и iOS; `rendering_method.android="gl_compatibility"` только Android), `main.gd`, `map_view.gd`, `simulation.gd` (#20, новая опциональная команда) — прошу посмотреть macOS-разработчика.
- **#20**: аннексия при капитуляции и баланс порога 1.5× — отдельные решения (меняют поведение ИИ и эталонные суммы).
- **Android**: пока только эмулятор; физический телефон, щипок, мобильные профили графики, release AAB (ключ подписи вне репозитория) не сделаны.
