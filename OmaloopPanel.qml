import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons

// omaloop panel entry point: a groovebox that drops down from the top edge.
// Hosted by omarchy-shell; summoned with:
//   omarchy-shell shell toggle io.github.joshuaswarren.omaloop
// Optional payload: {"preset":"acid","play":true}
//
// The panel owns the look and the keys. The Rust engine (engine/) owns time
// and sound; they talk JSON lines over stdin/stdout. The loop keeps playing
// when the panel is hidden; Stop (or the stop key) is what ends it.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.joshuaswarren.omaloop"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string enginePath: pluginDir + "/engine/target/release/omaloop-engine"
  readonly property string statePath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omaloop/pattern.json"
  readonly property string exportDir: Quickshell.env("HOME") + "/Music/omaloop"
  readonly property string shareBase: "https://joshuaswarren.github.io/omaloop/#"

  readonly property color background: Color.background
  readonly property color foreground: Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ---- state ----
  property bool opened: false
  property string engineState: "idle" // idle | missing | building | running | error
  property string lastErr: ""
  property bool playing: false
  property int playhead: -1
  property real bpm: 138
  property real swing: 0
  property real volume: 0.8
  property string preset: "y2k"
  property var tone: ({ cutoff: 0.45, detune: 0.5, drive: 0.2, sub: 0.5 })
  property int transpose: 0
  readonly property string keyName: ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][(9 + transpose) % 12] + "m"
  property bool libraryOpen: false
  property var libraryNames: []
  property int librarySel: -1
  property var grid: ({
    kick: [], snare: [], hat: [], ohat: [], bass: [], lead: []
  })
  property int cursorRow: 0
  property int cursorCol: 0
  property string statusText: ""
  property string themeName: ""

  readonly property var rows: [
    { id: "kick",  label: "KICK",  kind: "drum" },
    { id: "snare", label: "SNARE", kind: "drum" },
    { id: "hat",   label: "HAT",   kind: "drum" },
    { id: "ohat",  label: "OHAT",  kind: "drum" },
    { id: "bass",  label: "BASS",  kind: "note", root: 33 },
    { id: "lead",  label: "LEAD",  kind: "note", root: 57 }
  ]
  readonly property var presets: ["y2k", "acid", "minimal", "breaks"]
  readonly property var scale: [0, 2, 3, 5, 7, 8, 10]
  readonly property var stepKeys: [Qt.Key_Q, Qt.Key_W, Qt.Key_E, Qt.Key_R, Qt.Key_T, Qt.Key_Y, Qt.Key_U, Qt.Key_I,
                                   Qt.Key_O, Qt.Key_P, Qt.Key_A, Qt.Key_S, Qt.Key_D, Qt.Key_F, Qt.Key_G, Qt.Key_H]

  // First-party lock service: never map over the lock screen. Audio keeps
  // running while locked; it is a loop, not a notification.
  property var lockService: null
  readonly property bool sessionLocked: lockService !== null && lockService.locked === true
  Timer {
    interval: 1000; repeat: true; running: root.lockService === null
    onTriggered: {
      if (root.shell && typeof root.shell.serviceFor === "function") {
        var ls = root.shell.serviceFor("omarchy.lock")
        if (ls !== null && ls !== undefined) root.lockService = ls
      }
    }
  }

  // ---- lifecycle ----
  property var pendingPayload: null
  function open(payloadJson) {
    root.opened = true
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (engine.running) applyPayload(payload)
    else root.pendingPayload = payload
    ensureEngine()
  }
  function applyPayload(payload) {
    if (payload.preset) { send({ cmd: "preset", name: String(payload.preset) }); applyTheme() }
    if (payload.code) loadShared(String(payload.code))
    if (payload.play === true) send({ cmd: "play" })
    if (payload.preset || payload.code || payload.play) send({ cmd: "dump" })
  }
  function close() { root.opened = false }

  // Keyboard focus follows `opened`, not `visible` (the window stays mapped
  // during the slide-up). Prime with Exclusive on every open, then settle on
  // OnDemand: Hyprland only hands OnDemand focus to a surface as it maps, not
  // to an already-mapped one flipping from None. Same dance as the shell's
  // own KeyboardPanel.
  property bool focusPrimed: false
  Timer { id: focusPrime; interval: 75; onTriggered: if (root.opened) root.focusPrimed = true }
  onOpenedChanged: {
    if (opened) {
      focusPrimed = false
      focusPrime.restart()
      Qt.callLater(function() { if (root.opened) keys.forceActiveFocus() })
    } else {
      focusPrime.stop()
      focusPrimed = false
    }
  }

  // ---- engine process ----
  function ensureEngine() {
    if (engine.running || root.engineState === "building") return
    probe.running = true
  }

  Process {
    id: probe
    running: false
    command: ["test", "-x", root.enginePath]
    onExited: function(code) {
      if (code === 0) { root.engineState = "running"; engine.running = true }
      else root.engineState = "missing"
    }
  }

  Process {
    id: builder
    running: false
    workingDirectory: root.pluginDir + "/engine"
    command: ["cargo", "build", "--release"]
    stderr: SplitParser { onRead: function(line) { root.lastErr = String(line).trim().slice(0, 160) } }
    onStarted: { root.engineState = "building"; root.lastErr = "" }
    onExited: function(code) {
      if (code === 0) { root.engineState = "running"; engine.running = true }
      else { root.engineState = "error"; root.status("Build failed: " + root.lastErr) }
    }
  }

  Process {
    id: engine
    running: false
    command: [root.enginePath, "--state", root.statePath]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onEngineLine(String(line)) } }
    stderr: SplitParser { onRead: function(line) { root.lastErr = String(line).trim().slice(0, 160) } }
    onStarted: {
      root.engineState = "running"
      root.applyTheme()
      root.send({ cmd: "dump" })
      if (root.pendingPayload) { var p = root.pendingPayload; root.pendingPayload = null; root.applyPayload(p) }
    }
    onExited: function(code) {
      root.playing = false
      root.playhead = -1
      if (root.engineState === "running") {
        root.engineState = "error"
        root.status("Engine exited: " + (root.lastErr || ("code " + code)))
      }
    }
  }

  function send(obj) {
    if (!engine.running) return
    engine.write(JSON.stringify(obj) + "\n")
  }

  function onEngineLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.event === "step") { root.playhead = msg.index; root.playing = true; return }
    if (msg.event === "state") {
      var g = ({})
      for (var i = 0; i < root.rows.length; i++) {
        var id = root.rows[i].id
        g[id] = Array.isArray(msg[id]) ? msg[id].slice() : []
      }
      root.grid = g
      root.playing = msg.playing === true
      if (!root.playing) root.playhead = -1
      root.bpm = msg.bpm; root.swing = msg.swing; root.volume = msg.volume
      root.preset = msg.preset || root.preset
      root.tone = ({ cutoff: msg.cutoff, detune: msg.detune, drive: msg.drive, sub: msg.sub })
      root.transpose = Number(msg.transpose) || 0
      return
    }
    if (msg.event === "code") { copyProc.exec(["wl-copy", root.shareBase + msg.code]); root.status("Loop link copied. Paste it anywhere; Ctrl+V here loads one."); return }
    if (msg.event === "library") {
      root.libraryNames = Array.isArray(msg.names) ? msg.names : []
      if (root.librarySel >= root.libraryNames.length) root.librarySel = root.libraryNames.length - 1
      return
    }
    if (msg.event === "exported") { root.status("Exported " + String(msg.path).replace(Quickshell.env("HOME"), "~")); return }
    if (msg.event === "error") root.status(String(msg.message))
  }

  // ---- theme is the tone ----
  // Every Omarchy theme gets its own sound: the accent's hue picks the key
  // (12 hues, 12 keys, applied as a playback transpose so authored notes stay
  // put) and the oscillator spread, its lightness sets the filter, its
  // saturation sets drive, and a dark background puts more sub under the
  // kick. Switching theme retunes the loop live, no table of theme names.
  function applyTheme() {
    var a = root.accent, b = root.background
    var hue = a.hslHue < 0 ? 0.5 : a.hslHue
    send({
      cmd: "tone",
      cutoff: 0.15 + 0.7 * a.hslLightness,
      detune: 0.15 + 0.75 * hue,
      drive: 0.7 * a.hslSaturation,
      sub: 1.0 - b.hslLightness,
      transpose: Math.round(hue * 11)
    })
    send({ cmd: "dump" })
  }
  onAccentChanged: applyTheme()
  onBackgroundChanged: applyTheme()

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: root.themeName = String(text()).trim().split("-").map(function(w) { return w.charAt(0).toUpperCase() + w.slice(1) }).join(" ")
    onFileChanged: reload()
  }

  // ---- edits ----
  function cellOn(rowIdx, col) {
    var r = root.rows[rowIdx]
    var arr = root.grid[r.id] || []
    if (col >= arr.length) return false
    return r.kind === "drum" ? arr[col] === true : arr[col] > 0
  }
  function noteAt(rowIdx, col) {
    var arr = root.grid[root.rows[rowIdx].id] || []
    return col < arr.length ? arr[col] : 0
  }
  function toggleCell(rowIdx, col) {
    var r = root.rows[rowIdx]
    if (r.kind === "drum") send({ cmd: "step", track: r.id, index: col, on: !cellOn(rowIdx, col) })
    else send({ cmd: "note", track: r.id, index: col, note: cellOn(rowIdx, col) ? 0 : r.root + 12 })
    send({ cmd: "dump" })
  }
  function transpose(rowIdx, col, dir) {
    var r = root.rows[rowIdx]
    if (r.kind !== "note") return
    var n = noteAt(rowIdx, col)
    if (n === 0) { toggleCell(rowIdx, col); return }
    var ladder = []
    for (var o = -1; o <= 2; o++) for (var d = 0; d < root.scale.length; d++) ladder.push(r.root + o * 12 + root.scale[d])
    var best = 0
    for (var i = 1; i < ladder.length; i++) if (Math.abs(ladder[i] - n) < Math.abs(ladder[best] - n)) best = i
    var next = Math.max(0, Math.min(ladder.length - 1, best + dir))
    send({ cmd: "note", track: r.id, index: col, note: ladder[next] })
    send({ cmd: "dump" })
  }
  function noteName(n) {
    var names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    return names[n % 12] + (Math.floor(n / 12) - 1)
  }
  function setBpm(v) { send({ cmd: "bpm", value: Math.max(40, Math.min(300, v)) }); send({ cmd: "dump" }) }
  function setSwing(v) { send({ cmd: "swing", value: Math.max(0, Math.min(1, v)) }); send({ cmd: "dump" }) }
  function setVolume(v) { send({ cmd: "volume", value: Math.max(0, Math.min(1, v)) }); send({ cmd: "dump" }) }
  function togglePlay() { send({ cmd: "toggle" }); send({ cmd: "dump" }) }
  function stop() { send({ cmd: "stop" }); send({ cmd: "dump" }) }
  function nextPreset() {
    var i = (root.presets.indexOf(root.preset) + 1) % root.presets.length
    send({ cmd: "preset", name: root.presets[i] }); applyTheme()
    root.status("Preset " + root.presets[i])
  }
  function randomRow() { send({ cmd: "random", track: root.rows[root.cursorRow].id }); send({ cmd: "dump" }) }
  function clearRow() { send({ cmd: "clear", track: root.rows[root.cursorRow].id }); send({ cmd: "dump" }) }
  function exportLoop() {
    var d = new Date()
    var stamp = d.getFullYear() + "" + ("0" + (d.getMonth() + 1)).slice(-2) + ("0" + d.getDate()).slice(-2)
      + "-" + ("0" + d.getHours()).slice(-2) + ("0" + d.getMinutes()).slice(-2) + ("0" + d.getSeconds()).slice(-2)
    send({ cmd: "export", path: root.exportDir + "/" + root.preset + "-" + stamp + ".wav", bars: 4 })
    root.status("Rendering 4 bars…")
  }
  // ---- sharing and library ----
  Process { id: copyProc; running: false }
  Process {
    id: pasteProc
    running: false
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadShared(String(text || ""))
    }
  }
  function copyLink() { send({ cmd: "code" }) }
  function pasteLink() { pasteProc.running = true }
  function loadShared(text) {
    var m = /([A-Za-z0-9_-]{64})/.exec(text)
    if (!m) { root.status("No omaloop loop code in the clipboard"); return }
    send({ cmd: "load", code: m[1] })
    send({ cmd: "dump" })
    root.applyTheme()
    root.status("Loaded shared loop")
  }
  function openLibrary(prefill) {
    root.libraryOpen = true
    send({ cmd: "list" })
    nameField.text = prefill ? root.preset : ""
    Qt.callLater(function() { nameField.forceActiveFocus(); nameField.selectAll() })
  }
  function closeLibrary() { root.libraryOpen = false; keys.forceActiveFocus() }
  function saveAs(name) {
    send({ cmd: "save", name: name }); send({ cmd: "dump" })
    root.status("Saved " + name)
    nameField.text = ""
  }
  function openSaved(i) {
    if (i < 0 || i >= root.libraryNames.length) return
    send({ cmd: "open", name: root.libraryNames[i] }); applyTheme()
    root.status("Loaded " + root.libraryNames[i])
    closeLibrary()
  }
  function deleteSaved(i) {
    if (i < 0 || i >= root.libraryNames.length) return
    root.status("Deleted " + root.libraryNames[i])
    send({ cmd: "delete", name: root.libraryNames[i] })
  }

  function moveCursor(dr, dc) {
    root.cursorRow = ((root.cursorRow + dr) % root.rows.length + root.rows.length) % root.rows.length
    root.cursorCol = ((root.cursorCol + dc) % 16 + 16) % 16
  }

  function status(t) { root.statusText = t; statusClear.restart() }
  Timer { id: statusClear; interval: 4000; onTriggered: root.statusText = "" }

  function handleKey(event) {
    var k = event.key, shift = (event.modifiers & Qt.ShiftModifier) !== 0, ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    event.accepted = true
    if (ctrl) {
      if (k === Qt.Key_C) { copyLink(); return }
      if (k === Qt.Key_V) { pasteLink(); return }
      if (k === Qt.Key_S) { openLibrary(true); return }
      if (k === Qt.Key_O) { openLibrary(false); return }
      event.accepted = false
      return
    }
    if (k === Qt.Key_Escape) { root.close(); return }
    if (k === Qt.Key_Space) { togglePlay(); return }
    if (k === Qt.Key_Left) { moveCursor(0, -1); return }
    if (k === Qt.Key_Right) { moveCursor(0, 1); return }
    if (k === Qt.Key_Up) { moveCursor(-1, 0); return }
    if (k === Qt.Key_Down) { moveCursor(1, 0); return }
    if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_X) { toggleCell(root.cursorRow, root.cursorCol); return }
    if (k === Qt.Key_BracketLeft) { transpose(root.cursorRow, root.cursorCol, -1); return }
    if (k === Qt.Key_BracketRight) { transpose(root.cursorRow, root.cursorCol, 1); return }
    if (k === Qt.Key_Comma || k === Qt.Key_Less) { setBpm(root.bpm - (shift ? 5 : 1)); return }
    if (k === Qt.Key_Period || k === Qt.Key_Greater) { setBpm(root.bpm + (shift ? 5 : 1)); return }
    if (k === Qt.Key_Semicolon) { setSwing(root.swing - 0.05); return }
    if (k === Qt.Key_Apostrophe) { setSwing(root.swing + 0.05); return }
    if (k === Qt.Key_Minus) { setVolume(root.volume - 0.05); return }
    if (k === Qt.Key_Equal || k === Qt.Key_Plus) { setVolume(root.volume + 0.05); return }
    if (k === Qt.Key_Delete || k === Qt.Key_Backspace) { clearRow(); return }
    if (k >= Qt.Key_1 && k <= Qt.Key_6) { root.cursorRow = k - Qt.Key_1; return }
    var si = root.stepKeys.indexOf(k)
    if (si >= 0) {
      if (k === Qt.Key_P && shift) { nextPreset(); return }
      if (k === Qt.Key_R && shift) { randomRow(); return }
      if (k === Qt.Key_E && shift) { exportLoop(); return }
      root.cursorCol = si
      toggleCell(root.cursorRow, si)
      return
    }
    if (k === Qt.Key_C && shift) { clearRow(); return }
    event.accepted = false
  }

  // ---- window ----
  readonly property int cellW: 40
  readonly property int cellH: 26
  readonly property int gap: 4
  readonly property int labelW: 58
  readonly property int sheetW: 24 + labelW + 16 * (cellW + gap) + 8
  readonly property int sheetH: 46 + rows.length * (cellH + gap) + 34 + 12

  PanelWindow {
    id: window
    visible: (root.opened || slide.running) && !root.sessionLocked
    anchors { top: true; left: false; right: false; bottom: false }
    implicitWidth: root.sheetW
    implicitHeight: root.sheetH
    color: "transparent"
    WlrLayershell.namespace: "omaloop"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.opened
      ? (root.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: sheet
      width: parent.width
      height: parent.height
      y: root.opened ? 0 : -root.sheetH
      color: root.background
      border.color: root.tint(root.accent, 0.35)
      border.width: 1
      radius: Style.cornerRadius
      Behavior on y { NumberAnimation { id: slide; duration: 220; easing.type: Easing.OutCubic } }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) { root.handleKey(event) }
        MouseArea { anchors.fill: parent; onPressed: function(m) { keys.forceActiveFocus(); m.accepted = false } }
      }

      // ---- library overlay (over the grid) ----
      Rectangle {
        id: library
        visible: root.libraryOpen
        z: 5
        x: 12 + root.labelW
        y: 12 + 28 + 6
        width: 16 * (root.cellW + root.gap) - root.gap
        height: root.rows.length * (root.cellH + root.gap) - root.gap
        radius: 6
        color: root.background
        border.color: root.tint(root.accent, 0.5)
        border.width: 1

        Column {
          anchors.fill: parent
          anchors.margins: 10
          spacing: 6

          Row {
            width: parent.width
            spacing: 8
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "save as"
              color: root.foreground
              opacity: 0.6
              font.pixelSize: 11
              font.family: Style.fontFamily
            }
            Rectangle {
              width: parent.width - 180
              height: 24
              radius: 4
              color: root.tint(root.foreground, 0.08)
              border.color: nameField.activeFocus ? root.accent : "transparent"
              border.width: 1
              TextInput {
                id: nameField
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                font.pixelSize: 12
                font.family: Style.fontFamily
                selectByMouse: true
                maximumLength: 48
                Keys.onPressed: function(event) {
                  var k = event.key
                  event.accepted = true
                  if (k === Qt.Key_Escape) { root.closeLibrary(); return }
                  if (k === Qt.Key_Return || k === Qt.Key_Enter) {
                    if (text.trim() !== "") root.saveAs(text.trim())
                    else root.openSaved(root.librarySel)
                    return
                  }
                  if (k === Qt.Key_Down) { root.librarySel = Math.min(root.libraryNames.length - 1, root.librarySel + 1); return }
                  if (k === Qt.Key_Up) { root.librarySel = Math.max(0, root.librarySel - 1); return }
                  if (k === Qt.Key_Delete && text === "") { root.deleteSaved(root.librarySel); return }
                  event.accepted = false
                }
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Enter saves · Up/Down + Enter loads · Del removes · Esc"
              color: root.foreground
              opacity: 0.45
              font.pixelSize: 10
              font.family: Style.fontFamily
            }
          }

          ListView {
            id: libraryList
            width: parent.width
            height: parent.height - 30
            clip: true
            model: root.libraryNames
            currentIndex: root.librarySel
            delegate: Rectangle {
              required property string modelData
              required property int index
              width: libraryList.width
              height: 22
              radius: 4
              color: root.librarySel === index ? root.tint(root.accent, 0.25) : "transparent"
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 8
                text: modelData
                color: root.librarySel === index ? root.accent : root.foreground
                font.pixelSize: 12
                font.family: Style.fontFamily
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.librarySel = index; nameField.forceActiveFocus() }
                onDoubleClicked: root.openSaved(index)
              }
            }
            Text {
              anchors.centerIn: parent
              visible: root.libraryNames.length === 0
              text: "No saved loops yet. Type a name and press Enter."
              color: root.foreground
              opacity: 0.45
              font.pixelSize: 11
              font.family: Style.fontFamily
            }
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 6

        // ---- header ----
        Item {
          width: parent.width
          height: 28

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "omaloop"
              color: root.accent
              font.pixelSize: 15
              font.bold: true
              font.family: Style.fontFamily
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: (root.themeName !== "" ? "sounds like " + root.themeName + " · " : "") + root.keyName
              color: root.foreground
              opacity: 0.55
              font.pixelSize: 11
              font.family: Style.fontFamily
            }
            // the four tone bars: what your theme did to the synth
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 3
              Repeater {
                model: ["cutoff", "detune", "drive", "sub"]
                delegate: Rectangle {
                  required property string modelData
                  width: 4
                  height: 14
                  radius: 1
                  color: root.tint(root.accent, 0.18)
                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(2, parent.height * (Number(root.tone[parent.modelData]) || 0))
                    radius: 1
                    color: root.accent
                    Behavior on height { NumberAnimation { duration: 200 } }
                  }
                }
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11

            // preset
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.preset
              color: root.foreground
              font.pixelSize: 12
              font.family: Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.nextPreset() }
            }
            // bpm
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 4
              Text { text: "−"; color: root.foreground; opacity: 0.6; font.pixelSize: 13; font.family: Style.fontFamily
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.setBpm(root.bpm - 1) } }
              Text { text: Math.round(root.bpm) + " bpm"; color: root.foreground; font.pixelSize: 12; font.family: Style.fontFamily }
              Text { text: "+"; color: root.foreground; opacity: 0.6; font.pixelSize: 13; font.family: Style.fontFamily
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.setBpm(root.bpm + 1) } }
            }
            // swing
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "swing " + Math.round(root.swing * 100) + "%"
              color: root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Style.fontFamily
              MouseArea {
                anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                onClicked: root.setSwing(root.swing >= 0.6 ? 0 : root.swing + 0.1)
                onWheel: function(w) { root.setSwing(root.swing + (w.angleDelta.y > 0 ? 0.05 : -0.05)) }
              }
            }
            // share
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "share"
              color: root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.copyLink() }
            }
            // library
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "library"
              color: root.libraryOpen ? root.accent : root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.libraryOpen ? root.closeLibrary() : root.openLibrary(false) }
            }
            // export
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "export"
              color: root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.exportLoop() }
            }
            // stop
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰓛"
              color: root.urgent
              opacity: root.playing ? 1 : 0.3
              font.pixelSize: 15
              font.family: Style.fontFamily
              Behavior on opacity { NumberAnimation { duration: 120 } }
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.stop() }
            }
            // play / pause
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.playing ? "󰏤" : "󰐊"
              color: root.playing ? root.accent : root.foreground
              font.pixelSize: 15
              font.family: Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.togglePlay() }
            }
            // close
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰅖"
              color: root.foreground
              font.pixelSize: 16
              font.family: Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
            }
          }
        }

        // ---- grid ----
        Column {
          spacing: root.gap
          Repeater {
            model: root.rows
            delegate: Row {
              id: rowItem
              required property var modelData
              required property int index
              spacing: root.gap

              Item {
                width: root.labelW
                height: root.cellH
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: 6
                  text: rowItem.modelData.label
                  color: root.cursorRow === rowItem.index ? root.accent : root.foreground
                  opacity: root.cursorRow === rowItem.index ? 1 : 0.6
                  font.pixelSize: 11
                  font.bold: root.cursorRow === rowItem.index
                  font.family: Style.fontFamily
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.cursorRow = rowItem.index }
              }

              Repeater {
                model: 16
                delegate: Rectangle {
                  id: cell
                  required property int index
                  readonly property bool on: root.cellOn(rowItem.index, index)
                  readonly property bool isPlayhead: root.playhead === index
                  readonly property bool isCursor: root.cursorRow === rowItem.index && root.cursorCol === index
                  width: root.cellW
                  height: root.cellH
                  radius: 4
                  color: on ? (isPlayhead ? root.foreground : root.accent)
                            : root.tint(root.foreground, isPlayhead ? 0.22 : (Math.floor(index / 4) % 2 === 0 ? 0.08 : 0.05))
                  border.width: isCursor ? 2 : 0
                  border.color: root.foreground
                  Behavior on color { ColorAnimation { duration: 60 } }

                  Text {
                    anchors.centerIn: parent
                    visible: rowItem.modelData.kind === "note" && cell.on
                    text: root.noteName(root.noteAt(rowItem.index, cell.index))
                    color: root.background
                    font.pixelSize: 10
                    font.bold: true
                    font.family: Style.fontFamily
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.cursorRow = rowItem.index; root.cursorCol = cell.index; root.toggleCell(rowItem.index, cell.index) }
                    onWheel: function(w) {
                      root.cursorRow = rowItem.index; root.cursorCol = cell.index
                      root.transpose(rowItem.index, cell.index, w.angleDelta.y > 0 ? 1 : -1)
                    }
                  }
                }
              }
            }
          }
        }

        // ---- footer ----
        Item {
          width: parent.width
          height: 22

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 120
            elide: Text.ElideRight
            textFormat: Text.PlainText
            color: root.engineState === "error" || root.engineState === "missing" ? root.urgent : root.foreground
            opacity: root.statusText !== "" || root.engineState !== "running" ? 0.9 : 0.4
            font.pixelSize: 10
            font.family: Style.fontFamily
            text: root.engineState === "missing" ? "Engine not built yet: click Build (needs cargo) or run install.sh"
                : root.engineState === "building" ? "Building engine… " + root.lastErr
                : root.engineState === "error" ? (root.statusText || "Engine error: " + root.lastErr)
                : root.statusText !== "" ? root.statusText
                : "Space play · arrows · Enter toggle · Q-P A-H steps · [ ] note · , . bpm · ; ' swing · S-P preset · S-R random · S-E export · C-C copy link · C-V paste · C-S save · C-O library · Esc"
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.engineState === "missing" || root.engineState === "error"
            text: root.engineState === "missing" ? "Build" : "Retry"
            color: root.background
            font.pixelSize: 11
            font.bold: true
            font.family: Style.fontFamily
            leftPadding: 10; rightPadding: 10; topPadding: 3; bottomPadding: 3
            Rectangle { anchors.fill: parent; z: -1; radius: Style.cornerRadius; color: root.accent }
            MouseArea {
              anchors.fill: parent; cursorShape: Qt.PointingHandCursor
              onClicked: { if (root.engineState === "missing") builder.running = true; else root.ensureEngine() }
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.engineState === "running"
            text: "vol " + Math.round(root.volume * 100) + "%"
            color: root.foreground
            opacity: 0.5
            font.pixelSize: 10
            font.family: Style.fontFamily
            MouseArea {
              anchors.fill: parent; anchors.margins: -4
              onWheel: function(w) { root.setVolume(root.volume + (w.angleDelta.y > 0 ? 0.05 : -0.05)) }
            }
          }
        }
      }
    }
  }
}
