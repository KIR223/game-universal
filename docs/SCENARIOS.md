# Сценарии и моддинг

## Где лежат сценарии
- Встроенные: `game/scenarios/*.json`, список в `game/scenarios/index.json`.
- Пользовательские и модовые: `user://scenarios/*.json` (macOS: `~/Library/Application Support/Godot/app_userdata/Iron Dominion/scenarios/`; Windows: `%APPDATA%\Godot\app_userdata\Iron Dominion\scenarios\`; Android: `files/scenarios/` во внутреннем хранилище приложения). Редактор сохраняет сюда.

## Формат (schema_version 1)
```json
{
  "schema_version": 1, "id": "my_scenario", "name": "Название", "description": "…",
  "seed": 42, "start_date": "1936-01-01", "grace_days": 60,
  "countries": [{"tag": "NRM", "name": "…", "color": "#4a7fb5",
                 "ideology": "democracy", "treasury": 300, "manpower": 200,
                 "stock": {"steel": 200}, "techs": ["ind1"], "laws": {"economy": "partial"}}],
  "owners": {"12": "NRM", "13": null},      // провинция -> тег или null (нейтральная)
  "capitals": {"NRM": 18},
  "armies_mode": "replace",                   // "replace" заменяет стандартные армии
  "armies": [{"tag": "NRM", "province": 18, "divisions": ["infantry", "armor"]}],
  "deposits": {"18": {"oil": 5, "food": 3}},  // добыча в день
  "alliances": [["NRM", "SLV"]], "wars": [["KRS", "ALB"]],
  "disabled_events": ["strike"]
}
```
Порядок стран определяет, как расставляются столицы на процедурной карте. Номера провинций зависят от `seed`: при смене seed
правки границ, армий, ресурсов и столиц сбрасываются.

## Редактор
Главное меню → «Редактор сценариев» (или «Править» у сценария). Вкладки: Страны, Границы (кисть по провинциям, столицы), Армии,
Ресурсы, Дипломатия (союзы, войны с первого дня), События (включить/выключить), Файл (название, описание, seed, дата,
сохранение, открытие, «Играть»). Внизу виден статус проверки сценария.

## Моды данных
Любой файл из `data/` можно подменить, положив одноимённый файл в `user://mods/data/` (например `techs.json`, `events.json`,
`countries.json`). Подмена целиком заменяет файл. Проверьте результат запуском игры; для проверки структуры используйте
`python3 tools/validate_data.py` на копии файла в `data/`.

## Не реализовано
Редактор не создаёт новые события и решения (только включает и выключает существующие), не редактирует технологии и юниты —
для этого используйте моды данных. Не реализованы Steam Workshop и упаковка модов, загрузка скриптов в модах.
