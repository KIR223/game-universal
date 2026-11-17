# Asset licenses

Every third-party asset (art, audio, fonts, plugins, data) MUST be listed here with source URL and license
before it is committed. CI (`tools/check_licenses.py`) fails if `game/assets/` contains files not listed below.

| Asset | Source | License | Used in |
|-------|--------|---------|---------|
| `game/assets/fonts/PTSans-Regular.ttf`, `PTSans-Bold.ttf` (PT Sans Web) | https://github.com/google/fonts/tree/main/ofl/ptsans (ParaType) | SIL Open Font License 1.1 — text in `game/assets/fonts/OFL-PTSans.txt` (`OFL-PTSans.txt`) | all UI text and map labels (`game/ui/ui_font.gd`) |

Terrain, UI and map graphics are generated procedurally in code. Text is rendered with **PT Sans** (OFL 1.1, bundled in `game/assets/fonts/`);
glyphs it lacks fall back to Godot's built-in default font (Open Sans / Noto, MIT/OFL, bundled with the engine).


## Геоданные (data/world)

| Данные | Источник | Лицензия | Атрибуция |
|--------|----------|----------|-----------|
| Страны, области, спорные территории, озёра, реки, порты, аэропорты, дороги, железные дороги, регионы | Natural Earth 5.2.0-pre, https://www.naturalearthdata.com | Public domain | рекомендуется: Made with Natural Earth |
| Населённые пункты, названия, районы | GeoNames, https://www.geonames.org (`cities5000`, `admin1CodesASCII`, `admin2Codes`) | CC BY 4.0 | **обязательна**: Contains data from GeoNames |
| Высоты и глубины | Terrain Tiles (Tilezen), AWS Open Data | SRTM/GMTED2010/ETOPO1/NED и др. | **обязательна**: https://github.com/tilezen/joerd/blob/master/docs/attribution.md |
| Добыча нефти и угля по странам | Our World in Data, energy-data | CC BY 4.0 | **обязательна**: Our World in Data |

Подробности (даты, охват, ограничения): `docs/DATA_SOURCES.md`.
