# omaloop

A drop-down groovebox for [Omarchy](https://omarchy.org). Press SUPER+ALT+L. A 16-step drum machine, a bass line, and a lead synth slide down from the top of the screen in your theme's colors. Make a loop. Press SUPER+ALT+L again and it slides away while the loop keeps playing. Press Ctrl+C and the loop is a link you can tweet.

No samples, no DAW, no config. A small Rust engine generates four drums and two synths and sends them straight to PipeWire.

**Your theme has a sound.** The active theme's palette sets the key, the filter, oscillator spread, drive, and sub weight. Switch themes mid-loop and the loop changes key and tone with the colors.

![omaloop under Robzee84](docs/robzee84.png)
![the same loop under Tokyo Night](docs/tokyoled.png)

## Install

```sh
omarchy plugin add https://github.com/joshuaswarren/omaloop --enable
~/.config/omarchy/plugins/io.github.joshuaswarren.omaloop/install.sh --bind
```

`install.sh` builds the engine with cargo and registers the `omaloop://` link handler. With `--bind` it also appends a SUPER+ALT+L binding to `~/.config/hypr/bindings.lua`. Without `--bind` it prints the line for you to add yourself. If the engine is missing, the panel shows a Build button that runs the same build.

Toggle without the keybind:

```sh
omarchy-shell shell toggle io.github.joshuaswarren.omaloop
omarchy-shell shell summon io.github.joshuaswarren.omaloop '{"preset":"acid","play":true}'
```

Requires Omarchy 4 (Quattro) and Rust 1.75+.

## Play it

| Key | Does |
|---|---|
| `Space` | play / pause |
| arrows | move the cursor |
| `Enter` or `X` | toggle the cell under the cursor |
| `Q W E R T Y U I O P A S D F G H` | toggle steps 1-16 in the cursor's row |
| `1` - `6` | jump to a row |
| `[` `]` | move a bass or lead note down / up the scale (A minor) |
| `,` `.` | BPM -1 / +1 (Shift for 5) |
| `;` `'` | swing -5% / +5% |
| `-` `=` | volume |
| `Shift+P` | next preset (y2k, acid, minimal, breaks) |
| `Shift+R` | randomize the cursor's row (drums by density, notes in scale) |
| `Shift+C` or `Delete` | clear the cursor's row |
| `Shift+E` | export 4 bars to `~/Music/omaloop/<preset>-<time>.wav` |
| `Ctrl+C` | copy a share link for this loop |
| `Ctrl+V` | load a loop from a link or code on the clipboard |
| `Ctrl+S` | save to your library (type a name, Enter) |
| `Ctrl+O` | open the library (Up/Down, Enter loads, Delete removes) |
| `Esc` | hide (the loop keeps playing; the red square stops it) |

Mouse works too: click a cell, scroll on a note cell to transpose, click the preset name to cycle, scroll on swing or volume.

![editing a loop](docs/editing.png)

The current pattern is saved on every change to `~/.config/omaloop/pattern.json` and comes back on the next boot. Named loops live in `~/.config/omaloop/patterns/<name>.json`.

## Share a loop

Ctrl+C in the panel puts a link like this on your clipboard:

```
https://joshuaswarren.github.io/omaloop/#AUEEEJBVVQCAIQAAIQAAIQAAACEAACQAAAAAAAAAAAAARQBIAAAAAAB9QObMM4AH
```

The 64 characters after `#` are the whole loop: 4 drum masks, 32 notes, tempo, swing, tone, and key, in 48 bytes. Anyone who opens the link gets a browser page that plays the loop with the same synthesis as the desktop engine and shows the grid. If they have omaloop, the "open in omaloop" button hands the code to their panel through the `omaloop://` scheme, and their theme decides how it sounds. Ctrl+V in the panel loads a link or bare code from the clipboard.

## Why this exists

Omarchy 4 rebuilt the desktop as one Quickshell process. The community started shipping plugins for it overnight. The ones that spread make the desktop do something new in the theme's own colors. Every music plugin so far plays other people's music. omaloop makes the desktop itself an instrument.

In 2000 I produced techno as DJ Zip in FruityLoops with an Akai AX-60 and a Yamaha DD-50. "A Y2K Time Warp" won amp3.com's first Pick Hit Gold of the year on 2000-01-02. The default `y2k` preset is that loop's shape: four-on-the-floor at 138, a clap on 2 and 4, offbeat hats, a walking A-minor bass, and a detuned three-saw lead. The lead is a 3xOSC homage on purpose.

## How the theme becomes a sound

The panel reads the shell's live palette (`Color.accent`, `Color.background`). Whenever it changes, the panel sends one `tone` message to the engine:

| Palette | Synth |
|---|---|
| accent hue | the key (12 hues, 12 minor keys, applied as a playback transpose so your notes stay where you put them) and oscillator detune spread |
| accent lightness | filter cutoff (brighter accent, brighter lead and bass) |
| accent saturation | drive (tanh soft clip on the mix) |
| background darkness | sub weight under the kick and bass |

No table of theme names. Custom themes get a sound too. The header shows the key and four small bars for the current tone. Loading a preset, a saved loop, or a shared link keeps this rule: on your machine, your theme owns the sound.

## Architecture

```
OmaloopPanel.qml   Quickshell panel, theme colors from qs.Commons, all keys
      |  Quickshell.Io.Process: JSON lines over stdin / stdout
      v
omaloop-engine     Rust, ~600 lines: 16-step clock with swing, 6 voices,
      |            dotted-eighth delay, soft clip, state file, WAV export
      v
PipeWire           via cpal
```

The engine is usable on its own:

```sh
cd engine && cargo build --release
./target/release/omaloop-engine --render demo.wav --bars 4 --preset breaks
./target/release/omaloop-engine --render shared.wav --bars 4 --code AUEEEJBVVQCAIQAAIQAAIQAAACEAACQAAAAAAAAAAAAARQBIAAAAAAB9QObMM4AH
./target/release/omaloop-engine --play --state /tmp/p.json   # then type JSON lines
```

```json
{"cmd":"preset","name":"acid"}
{"cmd":"step","track":"ohat","index":14,"on":true}
{"cmd":"note","track":"lead","index":0,"note":69}
{"cmd":"tone","cutoff":0.2,"detune":0.8,"drive":0.5,"sub":0.9}
{"cmd":"swing","value":0.2}
{"cmd":"random","track":"bass"}
{"cmd":"code"}
{"cmd":"load","code":"AUEEEJBVVQCAIQAAIQAAIQAAACEAACQAAAAAAAAAAAAARQBIAAAAAAB9QObMM4AH"}
{"cmd":"save","name":"friday"}
{"cmd":"open","name":"friday"}
{"cmd":"list"}
{"cmd":"export","path":"/tmp/loop.wav","bars":8}
{"cmd":"dump"}
```

Events come back as `{"event":"step","index":n}` on every step. `dump` answers with `{"event":"state",...}`. A finished render sends `{"event":"exported","path":...}`. Drum tracks are `kick`, `snare`, `hat`, `ohat` (booleans). Note tracks are `bass` and `lead` (MIDI notes, 0 = rest). A closed hat chokes the open hat.

## Layout

```
manifest.json      Omarchy plugin manifest (panel + bar widget)
OmaloopPanel.qml   the drop-down
BarWidget.qml      "♪ loop" in the bar; click toggles the panel
install.sh         build, omaloop:// handler, optional SUPER+ALT+L binding
bin/omaloop-open   the omaloop:// handler
engine/            the Rust groovebox
docs/index.html    the share page (GitHub Pages), a JS port of the engine
```

## License

MIT
