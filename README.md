# IRON DOMINION

Глобальная стратегия (Grand Strategy / Geopolitical Simulator) на **Godot 4.7**. Один репозиторий для macOS, Windows, iOS и Android.

## Запуск

```bash
godot --path .                                   # игра
godot --headless --path . -s tests/run_tests.gd     # тесты
godot --headless --path . -s tests/run_ui_tests.gd  # UI-проверки на реальной карте
godot --path . -s tools/benchmark_world.gd          # бенчмарки карты
python3 tools/validate_data.py                   # проверка данных
```

Первый запуск на чистом клоне: `godot --headless --path . --import`.

## Управление

ЛКМ — выбор провинции / цель приказа · перетаскивание — камера · колесо / щипок — масштаб · Пробел — пауза · 1–4 — скорость · F5 — сохранить · Esc — снять выбор · Ctrl+F или / — поиск · M — режим карты · ПКМ — контекстное меню.

## Реальный мир

Сценарий «Современный мир» использует реальные геоданные (Natural Earth, GeoNames, Terrain Tiles, Our World in Data): страны, области, 70 тыс. городов, дороги, железные дороги, реки. Захват идёт по отдельным территориальным ячейкам, а не регионами целиком. Источники и ограничения — [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md).

## Документация

- [docs/WORLD_OVERHAUL_PLAN.md](docs/WORLD_OVERHAUL_PLAN.md) — реальная карта: план и статус
- [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md) — источники геоданных
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — производительность

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — архитектура и правила для всех платформ
- [docs/ROADMAP.md](docs/ROADMAP.md) — фазы и реальный статус
- [docs/HANDOFF.md](docs/HANDOFF.md) — состояние и следующие шаги
- [docs/SCENARIOS.md](docs/SCENARIOS.md) — сценарии, редактор, моды
- [ASSET_LICENSES.md](ASSET_LICENSES.md) — лицензии ассетов
