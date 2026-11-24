class_name Tutorial
extends RefCounted
## First-game hints, one step at a time. The step list and the completion checks are plain data/functions so they can be tested;
## main.gd shows the current step in a banner and moves on when its check passes. Progress is kept in GameSettings.

## Each step: id, banner text. Completion is decided by `done(step_id, ctx)` from a small snapshot of the game state.
const STEPS := [
	{"id": "select", "text": "1/6  Нажмите на любую территорию на карте: внизу появится карточка с населением, ресурсами и армиями."},
	{"id": "time", "text": "2/6  Запустите время: кнопка ▶ вверху или Пробел. Скорость — клавиши 1–4."},
	{"id": "economy", "text": "3/6  Откройте панель «Экономика» (значок монеты слева): запасы, баланс и торговля."},
	{"id": "tech", "text": "4/6  Откройте «Технологии» (колба) и поставьте любое исследование в очередь."},
	{"id": "army", "text": "5/6  Выберите свою армию в карточке территории, затем кликните по цели на карте — армия пойдёт."},
	{"id": "diplomacy", "text": "6/6  Откройте «Дипломатия»: союзы, эмбарго, санкции и объявление войны. Готово — удачи!"},
]


## ctx: {"selected": bool, "day": int, "panel": String, "queue": int, "moving": bool}
static func done(step_id: String, ctx: Dictionary) -> bool:
	match step_id:
		"select": return bool(ctx.get("selected", false))
		"time": return int(ctx.get("day", 0)) > 0
		"economy": return str(ctx.get("panel", "")) == "economy"
		"tech": return int(ctx.get("queue", 0)) > 0
		"army": return bool(ctx.get("moving", false))
		"diplomacy": return str(ctx.get("panel", "")) == "diplomacy"
	return false


## Index of the first step that is not finished yet (STEPS.size() when all are).
static func first_open(ctx_history: Dictionary) -> int:
	for i in STEPS.size():
		if not ctx_history.get(STEPS[i]["id"], false):
			return i
	return STEPS.size()
