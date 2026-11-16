# Asset licenses

Every third-party asset (art, audio, fonts, plugins, data) MUST be listed here with source URL and license
before it is committed. CI (`tools/check_licenses.py`) fails if `game/assets/` contains files not listed below.

| Asset | Source | License | Used in |
|-------|--------|---------|---------|
| *(none yet)* | | | |

Currently the game uses **no external assets**: terrain, UI and map graphics are generated procedurally in code;
text is rendered with Godot's built-in default font (Open Sans / Noto, MIT/OFL, bundled with the engine).
