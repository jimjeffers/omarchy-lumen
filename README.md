# Lumen for the Omarchy bar

An Omarchy bar widget for external monitors over DDC/CI, from an icon next
to the Display widget. Every monitor gets brightness, contrast and volume;
models with a [Lumen profile](https://github.com/jimjeffers/lumen-ddc#supported-monitors)
also get their own controls, such as picture modes and backlights.
Scroll the icon to change brightness; click it for the panel. With two or
more monitors, the picker in the top right chooses whether the controls
edit all of them or just one; the panel remembers the choice.

![The Lumen panel](preview.png)

The panel is keyboard driven: arrows move between rows and adjust values,
Escape closes it. **Open Lumen** launches the full app, which also has color
temperature. Controls with more to say show an info icon; hover it for the
details.

## Requirements

- [Lumen](https://github.com/jimjeffers/lumen-ddc) (`lumen-ddc`) 0.4 or
  newer, the app that talks to the monitors. The widget runs
  `lumen-ddc state` and `lumen-ddc set`.
- `ddcutil`, and DDC/CI turned on in each monitor's on-screen menu.
- Your user needs access to `/dev/i2c-*` (Omarchy's default setup allows it;
  otherwise add yourself to the `i2c` group).

## Supported monitors

| Monitor | Controls in the panel |
|---|---|
| Any DDC/CI monitor | Brightness, contrast, speaker volume |
| BenQ RD320U | Picture mode, MoonHalo on/off, brightness, contrast, speaker volume |

A monitor without a profile still gets the standard controls, and the panel
says so with a link to adding one.

## How it fits together

The widget has no monitor knowledge of its own. Lumen matches each monitor to
a profile and reports its controls in `lumen-ddc state`:

```json
{ "connector": "DP-2", "model": "BenQ RD320U",
  "profile": { "id": "benq-rd320u", "supported": true },
  "controls": [
    { "id": "mode", "type": "choice", "value": 48, "options": [{ "value": 48, "label": "Coding Dark" }] },
    { "id": "halo", "type": "toggle", "value": 33, "options": [{ "value": 33, "label": "On" }, { "value": 17, "label": "Off" }], "note": "…" },
    { "id": "brightness", "type": "slider", "value": 36, "max": 100 }
  ] }
```

`Model.js` turns that into rows (a slider, a row of buttons, or a switch per
control, in profile order, skipping controls marked `"panel": false`), and
`Panel.qml` draws them. Changes go back through `lumen-ddc set TARGET ID VALUE`.

So **adding a monitor needs no change here**: write a profile in the Lumen
repository, following
[docs/adding-a-monitor.md](https://github.com/jimjeffers/lumen-ddc/blob/main/docs/adding-a-monitor.md),
and its controls appear in the panel. Changes to this repository are for the
panel itself: a new control type, layout, or translations.

## Install

```sh
omarchy plugin add https://github.com/jimjeffers/omarchy-lumen --enable
```

Then add **Lumen** to the bar from the bar settings if it doesn't appear.

## Settings

| Setting | Default | |
|---|---|---|
| Path to lumen-ddc | empty | Leave empty to use `lumen-ddc` from `PATH` |

## Remove

```sh
omarchy plugin remove io.github.jimjeffers.lumen
```

## Notes

- English only for now; translations go in `i18n/<code>.json`.
- Tests for the panel logic: `node tests/model.test.js`.
- Check the plugin with `omarchy plugin validate .` before sending a change.

## License

MIT
