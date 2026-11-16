# Android

**Статус:** debug APK собирается и подписывается (arm64-v8a, minSdk 24, targetSdk 36). **На устройстве/эмуляторе не запускался** — их на машине разработки нет. Сенсорное управление, мобильные профили графики и оптимизация ещё не сделаны (игра пока управляется мышью/клавиатурой).

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
