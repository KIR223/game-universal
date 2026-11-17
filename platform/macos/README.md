# IRON DOMINION для macOS

Собранное и проверенное: `.app` (universal: arm64 + x86_64), экспортировано шаблонами Godot 4.7.2, подписано ad-hoc, запускается (память в меню ≈ 100 МБ, ошибок в журнале нет), `.dmg` ≈ 156 МБ.

## Сборка
Нужны export templates 4.7.2 (Godot → Manage Export Templates).
```bash
mkdir -p build/macos
godot --headless --path . --export-release "macOS" build/macos/IronDominion.app
hdiutil create -volname "Iron Dominion" -srcfolder build/macos/IronDominion.app -ov -format UDZO build/macos/IronDominion.dmg
```
Пресет `macOS` лежит в `export_presets.cfg`; в сборку входят карты `data/world`, `world_visual`, `world_hd`, `world_xl`.

## Что не сделано (нужны ваши действия)
- **Нотаризация и подпись Developer ID** — нужна платная Apple Developer Program и ваш сертификат; сейчас подпись ad-hoc (при первом запуске: правый клик → «Открыть»). Bundle ID `com.example.irondominion` — замените на свой в пресете.
- Иконка приложения временная (`platform/ios/icon_1024.png`, сгенерирована в коде).
- Автоматическая сборка `.app` в CI не настроена (в CI собираются Windows и Android).
