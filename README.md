# omaloop

A drop-down groovebox for [Omarchy](https://omarchy.org). Press a key, a 16-step drum machine and a three-oscillator synth slide down from the top of the screen in your theme's colors, and you make a loop. Press the key again and it slides away while the loop keeps playing.

No samples, no DAW, no config. Everything is synthesized in a small Rust engine and routed straight to PipeWire.

## Why this, why now

Omarchy 4 "Quattro" (August 2026) rebuilt the desktop as one long-running Quickshell process, and the community turned it into a plugin surface: 1,700+ plugins in two weeks, an official marketplace on the way, and an Artists in Residence program paying plugin and theme authors. The plugins that spread are the ones that make the desktop *do* something new in the theme's own colors: omatunes, omakade, the Quake console in 4.1.

Nobody has built an instrument. Every music plugin so far plays other people's music (radio, Jellyfin, Soma.fm). omaloop makes the desktop itself an instrument.

Two hooks make it shareable:

1. **Your theme has a sound.** The synth's cutoff, detune, and kick decay derive from the active Omarchy theme. Tokyo Night is dark and filtered. Gruvbox is warm. Switch theme mid-loop and the sound changes with the colors. "What does Catppuccin sound like?" is a 15-second clip people will post.
2. **It is a Quake console for beats.** Super+L drops it down over whatever you are doing. The loop keeps running when you dismiss it. Tiling-window-manager people already love this interaction; the 4.1 console announcement proved it.

## Lineage

In 2000 I produced techno as DJ Zip in FruityLoops with an Akai AX-60 and a Yamaha DD-50. "A Y2K Time Warp" won amp3.com's first Pick Hit Gold of the year on 2000-01-02. The default pattern in this engine is that loop's shape: four-on-the-floor at 138, a clap on 2 and 4, offbeat hats, and a detuned three-saw lead in A minor. The synth is a 3xOSC homage on purpose.

## Status

| Piece | State |
|---|---|
| `engine/` Rust groovebox (cpal to PipeWire, JSON-lines protocol, offline WAV render) | Working. Verified 2026-09-05: sample-exact 2-bar render, live stream on PipeWire 1.6.8, all commands applied. |
| `manifest.json` Omarchy plugin manifest (panel + bar widget) | Written to the schema used by the author's other published plugins. |
| `OmaloopPanel.qml` drop-down UI | Not written yet. Next. |
| `BarWidget.qml` bar toggle | Not written yet. |
| Theme-to-tone mapping | Engine accepts `tone`; the theme table is not written yet. |

## Run the engine today

```sh
cd engine
cargo build --release

# render two bars of the default Y2K loop to a file
./target/release/omaloop-engine --render demo.wav --bars 2

# play live through PipeWire and drive it from stdin
./target/release/omaloop-engine --play
```

Then type JSON lines:

```json
{"cmd":"bpm","value":140}
{"cmd":"step","track":"snare","index":8,"on":true}
{"cmd":"note","index":1,"note":64}
{"cmd":"tone","cutoff":0.2,"detune":0.8}
{"cmd":"stop"}
{"cmd":"dump"}
```

The engine prints `{"event":"step","index":n}` on every step so a UI can draw the playhead, and `{"event":"state",...}` in reply to `dump`.

## Architecture

```
OmaloopPanel.qml  (Quickshell, theme colors from qs.Commons)
      |  Quickshell.Io.Process, stdin/stdout JSON lines
      v
omaloop-engine    (Rust: 16-step sequencer, synth voices, cpal)
      |
      v
PipeWire
```

QML owns the look and the keys. Rust owns time and sound. The two talk over a protocol small enough to type by hand, which is also how it gets tested.

## Roadmap

1. `OmaloopPanel.qml`: 3 drum rows plus a note row, 16 columns, playhead, BPM, keyboard-first (1-4 select row, Q-P and A-; toggle steps, Space play/stop).
2. Theme table: read `~/.config/omarchy/current/theme` and send `tone` on change.
3. Bar widget with a tiny live playhead.
4. Pattern save/load as JSON in `~/.config/omaloop/`.
5. `omarchy plugin add https://github.com/joshuaswarren/omaloop` install path and marketplace listing.

## License

MIT
