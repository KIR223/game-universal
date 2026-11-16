# IRON DOMINION

Глобальная стратегия (Grand Strategy / Geopolitical Simulator) на **Godot 4.7**. Один репозиторий для macOS, Windows, iOS и Android.

## Запуск

```bash
godot --path .                                   # игра
godot --headless --path . -s tests/run_tests.gd  # тесты
python3 tools/validate_data.py                   # проверка данных
```

Первый запуск на чистом клоне: `godot --headless --path . --import`.

## Управление

ЛКМ — выбор провинции / цель приказа · перетаскивание — камера · колесо / щипок — масштаб · Пробел — пауза · 1–4 — скорость · F5 — сохранить · Esc — снять выбор армии.

## Документация

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — архитектура и правила для всех платформ
- [docs/ROADMAP.md](docs/ROADMAP.md) — фазы и реальный статус
- [docs/HANDOFF.md](docs/HANDOFF.md) — состояние и следующие шаги
- [docs/SCENARIOS.md](docs/SCENARIOS.md) — сценарии, редактор, моды
- [ASSET_LICENSES.md](ASSET_LICENSES.md) — лицензии ассетов
