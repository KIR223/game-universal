# Android

**Статус:** debug APK собирается и подписывается (arm64-v8a для телефона, x86_64 для эмулятора; minSdk 24, targetSdk 36). **Проверено в эмуляторе** (Android 35 x86_64, Google APIs, хост-GPU): главное меню, список сценариев, касанием запущен «Современный мир», выбор государства с реальной картой всех 205 стран отображается. **На физическом устройстве не запускался.** Дальше выбор страны/игра, сенсорное управление, мобильные профили графики и оптимизация ещё не проверены/не сделаны.

## Рендерер
Vulkan (Forward Mobile) на эмуляторе даёт чёрный экран (`Couldn't present to Vulkan queue`) и с хост-GPU, и с SwiftShader. Для Android включён Compatibility (OpenGL ES): `renderer/rendering_method.android="gl_compatibility"` (только Android, desktop/iOS не затронуты). С программным GL (SwiftShader) интерфейс не рисуется (лимит uniform), с хост-GPU эмулятора (`-gpu host`) всё работает. Как поведёт себя реальный телефон — не проверено.

## Эмулятор
`avdmanager` в этой версии создаёт AVD с `avd.name=<build>` и нулевым экраном — в `config.ini` исправлены имя, `hw.lcd.*`, `hw.gpu.mode=host`, `disk.dataPartition.size=3G` (на диске C: мало места). Запуск: `emulator -avd iron_test -gpu host`; пакет — `com.kir223.irondominion/com.godot.game.GodotAppLauncher`.

## Инструменты (Windows, установлены вне репозитория)
- JDK 17: `winget install Microsoft.OpenJDK.17` → `C:\Program Files\Microsoft\jdk-17.0.21.21-hotspot`
- Android SDK (cmdline-tools из dl.google.com): `%LOCALAPPDATA%\Android\Sdk` — `platform-tools`, `platforms;android-36`, `build-tools;36.1.0`, `ndk;29.0.14206865` (версии из `android_source.zip` шаблона Godot 4.7.2).
- Godot export templates 4.7.2 (`%APPDATA%\Godot\export_templates\4.7.2.stable`).
- Godot Editor Settings: `export/android/android_sdk_path`, `export/android/java_sdk_path`, `export/android/debug_keystore` (debug-ключ создаётся `keytool`, в репозиторий не кладётся).

## Сборка debug APK
```
godot --headless --path . --import
godot --headless --path . --export-debug "Android debug APK" build/android/IronDominion-debug.apk
adb install -r build/android/IronDominion-debug.apk
```
Нужна настройка проекта `rendering/textures/vram_compression/import_etc2_astc=true` (добавлена; нужна и для iOS).

## Не сделано
Release AAB и подпись release-ключом (ключи не хранить в репозитории; публикация в Google Play — только с разрешения владельца), запуск на устройстве, сенсорное управление (перемещение/щипок/выбор/панели), профили графики, автосохранение при сворачивании, CI-сборка APK.
