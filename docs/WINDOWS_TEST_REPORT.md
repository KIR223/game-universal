# Windows test report

Дата: 2026-11-16 · Коммит: `ab078a2` · Godot 4.7.2 · Windows 11 x64 · RTX 5060 Ti

| Проверка | Результат |
|---|---|
| `godot --headless --path . --import` | OK |
| `tests/run_tests.gd` | 1839 passed, 0 failed |
| `tests/run_ui_tests.gd` | 47 passed, 0 failed |
| `python tools/validate_data.py` | OK |
| Запуск игры окном (`--quit-after 300`) | OK, exit 0, Vulkan 1.4 |
| `tools/benchmark_world.gd` | не запускался (см. следующий этап) |
| Экспорт EXE (`build/windows/IronDominion.exe`, 105 МБ) | OK, standalone запуск exit 0 |

Замечание: UI-тесты печатают предупреждения о RID-утечках при выходе (headless dummy renderer) — тесты при этом проходят.

