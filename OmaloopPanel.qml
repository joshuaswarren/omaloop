import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons as Commons

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
  readonly property string videoDir: Quickshell.env("HOME") + "/Videos/omaloop"
  readonly property string shareBase: "https://joshuaswarren.github.io/omaloop/#"

  readonly property color background: Commons.Color.background
  readonly property color foreground: Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color muted: Commons.Color.muted
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
  property bool shareMenuOpen: false
  property bool copyLinkPending: false
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

  // ---- frozen video export state ----
  property bool videoDialogOpen: false
  property bool videoPreviewExpanded: false
  property bool videoBusy: false
  property bool videoComplete: false
  property bool videoInstallPrompt: false
  property bool videoCancelRequested: false
  property bool pendingVideoDialog: false
  property string videoAspect: "portrait"
  readonly property string videoQuality: "high"
  property int videoRepetitions: 4
  property string videoHandle: ""
  property string videoDestination: videoDir
  property string videoJobId: ""
  property string videoOutputPath: ""
  property string videoOutputFolder: videoDir
  property string videoStatus: ""
  property real videoProgress: 0
  property string previewPath: ""
  property string previewJobId: ""
  property bool previewReady: false
  property bool previewRestartPending: false
  property int videoJobSerial: 0
  property string pendingVideoJson: ""
  property string pendingPreviewJson: ""
  property string ffmpegProbeText: ""
  property string localSendTarget: ""
  property string fileProbePurpose: ""

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
  function close() { root.shareMenuOpen = false; root.opened = false }

  // Keyboard focus follows `opened`, not `visible` (the window stays mapped
  // during the slide-up). While the panel is down it holds the keyboard
  // exclusively, like the shell's menus: an instrument you are playing should
  // never leak keystrokes into the window underneath. Esc releases it and
  // the loop keeps playing.
  onOpenedChanged: if (opened) Qt.callLater(function() { if (root.opened) keys.forceActiveFocus() })

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
    command: ["cargo", "build", "--release", "--locked"]
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
      if (root.pendingGenerate) { root.pendingGenerate = false; root.generateFromTheme() }
    }
    onExited: function(code) {
      root.playing = false
      root.playhead = -1
      root.copyLinkPending = false
      root.pendingVideoDialog = false
      if (root.engineState === "running") {
        root.engineState = "error"
        root.status("Engine exited: " + (root.lastErr || ("code " + code)))
      }
    }
  }

  // Video rendering is deliberately a separate short-lived engine process.
  // It owns ffmpeg, emits job-id-keyed events, and can cancel its child
  // without touching the realtime engine or another user's ffmpeg process.
  Process {
    id: videoProcess
    running: false
    command: [root.enginePath, "--render-video"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onVideoLine(String(line)) } }
    stderr: SplitParser { onRead: function(line) { root.videoStatus = String(line).trim().slice(0, 240) } }
    onStarted: {
      root.videoStatus = "Rendering…"
      root.videoProgress = 0
      videoProcess.write(root.pendingVideoJson + "\n")
    }
    onExited: function(code) {
      if (!root.videoBusy) return
      var cancelled = root.videoCancelRequested
      root.videoBusy = false
      root.videoCancelRequested = false
      root.videoComplete = false
      root.videoStatus = cancelled
        ? "Export cancelled; no video was published"
        : "Export process stopped" + (code ? " (code " + code + ")" : "")
      root.status(root.videoStatus)
    }
  }

  Process {
    id: previewProcess
    property string writingPath: ""
    running: false
    command: [root.enginePath, "--render-preview"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.onPreviewLine(String(line)) } }
    stderr: SplitParser { onRead: function(line) { root.videoStatus = String(line).trim().slice(0, 240) } }
    onStarted: {
      if (root.previewPath === "") {
        previewProcess.running = false
        return
      }
      writingPath = root.previewPath
      previewProcess.write(root.pendingPreviewJson + "\n")
    }
    onExited: function(code) {
      // A cancelled renderer can still have the file open until it exits.
      if (code !== 0 || writingPath !== root.previewPath) root.removePreviewFile(writingPath)
      writingPath = ""
      if (root.previewRestartPending) {
        root.previewRestartPending = false
        Qt.callLater(function() {
          if (!previewProcess.running && root.videoDialogOpen && root.previewPath !== "") previewProcess.running = true
        })
      }
    }
  }

  Process {
    id: ffmpegProbe
    running: false
    command: ["ffmpeg", "-hide_banner", "-encoders"]
    stdout: SplitParser { onRead: function(line) { root.ffmpegProbeText += String(line) + "\n" } }
    stderr: SplitParser { onRead: function(line) { root.ffmpegProbeText += String(line) + "\n" } }
    onStarted: root.ffmpegProbeText = ""
    onExited: function(code) {
      var h264 = /\blibx264\b/.test(root.ffmpegProbeText)
      var aac = /\baac\b/.test(root.ffmpegProbeText)
      if (code === 0 && h264 && aac) root.beginVideoExport()
      else {
        root.videoStatus = "FFmpeg is missing or lacks software libx264 and AAC"
        root.videoInstallPrompt = true
      }
    }
  }

  // Omarchy's supported package flow is visible and user-confirmed. It is
  // never started by feature detection or at plugin startup.
  Process {
    id: ffmpegInstall
    running: false
    command: ["omarchy-launch-floating-terminal-with-presentation", "omarchy-pkg-add ffmpeg"]
    onStarted: root.videoStatus = "FFmpeg installation is running in a terminal…"
    onExited: function(code) {
      root.videoInstallPrompt = false
      if (code !== 0) {
        root.videoStatus = "Could not launch the FFmpeg install terminal; existing features are unchanged"
        root.videoInstallPrompt = true
      } else {
        root.videoStatus = "Checking FFmpeg again…"
        ffmpegProbe.running = true
      }
    }
  }

  Process {
    id: openVideoProc
    running: false
    command: ["xdg-open", root.videoOutputPath]
  }
  Process {
    id: openFolderProc
    running: false
    command: ["xdg-open", root.videoOutputFolder]
  }
  Process {
    id: fileProbe
    running: false
    command: ["test", "-f", root.videoOutputPath]
    onExited: function(code) {
      if (code !== 0) { root.status("The exported video is no longer available"); return }
      if (root.fileProbePurpose === "open") openVideoProc.running = true
      else if (root.fileProbePurpose === "send") localSendProbe.running = true
    }
  }
  Process {
    id: localSendProbe
    running: false
    command: ["omarchy-cmd-present", "localsend-cli"]
    onExited: function(code) {
      if (code !== 0) { root.status("LocalSend CLI is not installed; use Open folder to transfer the file"); return }
      localSendProc.running = true
    }
  }
  Process {
    id: localSendProc
    running: false
    command: ["omarchy-launch-tui", "--app-id=org.omarchy.localsend", "localsend-cli", "-f", root.localSendTarget]
    onExited: function(code) {
      if (code === 0) root.status("LocalSend opened. Choose a recipient and approve the transfer on the device list.")
      else root.status("Could not open LocalSend; use Open folder to transfer the file")
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
      if (root.pendingVideoDialog) {
        root.pendingVideoDialog = false
        root.openVideoDialog()
      } else if (root.videoDialogOpen && !root.videoBusy) {
        root.requestVideoPreview()
      }
      return
    }
    if (msg.event === "code" && root.copyLinkPending) {
      root.copyLinkPending = false
      const code = String(msg.code || "")
      if (code === "") root.status("Could not create a loop link")
      else copyProc.exec(["sh", "-c", 'exec wl-copy "$1"', "omaloop-copy", root.shareBase + code])
      return
    }
    if (msg.event === "library") {
      root.libraryNames = Array.isArray(msg.names) ? msg.names : []
      if (root.librarySel >= root.libraryNames.length) root.librarySel = root.libraryNames.length - 1
      return
    }
    if (msg.event === "exported") { root.status("Exported " + String(msg.path).replace(Quickshell.env("HOME"), "~")); return }
    if (msg.event === "error") root.status(String(msg.message))
  }

  function onPreviewLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.event === "preview_ready" && String(msg.jobId || "") === root.previewJobId && String(msg.path || "") === root.previewPath) {
      root.previewReady = true
    }
  }

  function onVideoLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (String(msg.jobId || "") !== root.videoJobId) return
    if (msg.event === "video_export_progress") {
      root.videoProgress = Math.max(0, Math.min(1, Number(msg.progress) || 0))
      root.videoStatus = msg.phase === "frames" && msg.frames ? "Encoding frame " + msg.frame + " / " + msg.frames : (String(msg.phase || "Rendering") + "…")
      return
    }
    if (msg.event === "video_exported") {
      root.videoBusy = false
      root.videoCancelRequested = false
      root.videoOutputPath = root.pendingVideoOutputPath
      root.videoComplete = true
      root.videoProgress = 1
      root.videoStatus = "Video ready"
      root.status("Video ready: " + root.videoOutputPath.replace(Quickshell.env("HOME"), "~"))
      return
    }
    if (msg.event === "video_export_cancelled") {
      root.videoBusy = false
      root.videoCancelRequested = false
      root.videoStatus = "Export cancelled; no video was published"
      root.status(root.videoStatus)
      return
    }
    if (msg.event === "error") {
      root.videoBusy = false
      root.videoCancelRequested = false
      root.videoComplete = false
      root.videoStatus = String(msg.message || "Video export failed")
      root.status(root.videoStatus)
    }
  }

  property string pendingVideoOutputPath: ""
  function frozenPattern() {
    return {
      preset: root.preset,
      bpm: Number(root.bpm), swing: Number(root.swing), volume: Number(root.volume),
      cutoff: Number(root.tone.cutoff), detune: Number(root.tone.detune),
      drive: Number(root.tone.drive), sub: Number(root.tone.sub), transpose: Number(root.transpose),
      kick: (root.grid.kick || []).slice(), snare: (root.grid.snare || []).slice(),
      hat: (root.grid.hat || []).slice(), ohat: (root.grid.ohat || []).slice(),
      bass: (root.grid.bass || []).slice(), lead: (root.grid.lead || []).slice()
    }
  }
  function nextVideoJobId() {
    root.videoJobSerial += 1
    return String(Date.now()) + "-" + String(root.videoJobSerial)
  }
  function videoTimestamp() {
    var d = new Date()
    return d.getFullYear() + "" + ("0" + (d.getMonth() + 1)).slice(-2) + ("0" + d.getDate()).slice(-2)
      + "-" + ("0" + d.getHours()).slice(-2) + ("0" + d.getMinutes()).slice(-2) + ("0" + d.getSeconds()).slice(-2)
      + "-" + root.videoJobSerial
  }
  function safeVideoStem() {
    var stem = String(root.preset || "loop").replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "")
    return (stem || "loop") + "-" + root.videoAspect + "-" + root.videoTimestamp()
  }
  function videoOutputForJob() {
    var destination = String(root.videoDestination || root.videoDir).trim().replace(/\/+$/, "")
    if (destination.indexOf("~/") === 0) destination = Quickshell.env("HOME") + destination.slice(1)
    if (destination === "") destination = root.videoDir
    return destination + "/" + root.safeVideoStem() + ".mp4"
  }
  function videoDurationSeconds() { return 240.0 / Math.max(40, Math.min(300, Number(root.bpm) || 138)) * root.videoRepetitions }
  function durationLabel() {
    var seconds = Math.max(0, root.videoDurationSeconds())
    return seconds.toFixed(2) + "s"
  }
  function videoJobObject(jobId) {
    return {
      jobId: jobId,
      pattern: root.frozenPattern(),
      palette: ({ background: String(root.background), foreground: String(root.foreground), accent: String(root.accent), muted: String(root.muted) }),
      fontFamily: String(Commons.Style.fontFamily),
      aspect: root.videoAspect,
      quality: root.videoQuality,
      repetitions: root.videoRepetitions,
      handle: root.videoHandle.trim()
    }
  }
  function requestVideoPreview() {
    if (!engine.running || root.videoBusy) return
    root.invalidateVideoResult()
    root.clearVideoPreview()
    root.previewJobId = root.nextVideoJobId()
    // A new file URL for each preview lets the Image load the new frame directly.
    root.previewPath = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omaloop-preview-" + root.previewJobId + ".ppm"
    var job = root.videoJobObject(root.previewJobId)
    job.previewPath = root.previewPath
    root.pendingPreviewJson = JSON.stringify(job)
    if (previewProcess.running) {
      root.previewRestartPending = true
      previewProcess.running = false
    } else if (!root.previewRestartPending) {
      previewProcess.running = true
    }
  }
  function removePreviewFile(path) {
    if (path !== "") Quickshell.execDetached(["rm", "-f", "--", path])
  }
  function clearVideoPreview() {
    const finishedPath = root.previewReady && root.previewPath !== previewProcess.writingPath ? root.previewPath : ""
    root.previewReady = false
    root.previewPath = ""
    root.removePreviewFile(finishedPath)
  }
  function invalidateVideoResult() {
    if (root.videoBusy || !root.videoComplete) return
    root.videoComplete = false
    root.videoOutputPath = ""
    root.videoStatus = ""
  }
  function openVideoDialog() {
    if (!engine.running) { root.status("Build the engine before opening video export"); return }
    root.videoDialogOpen = true
    root.videoInstallPrompt = false
    root.videoComplete = false
    root.videoStatus = ""
    root.videoProgress = 0
    root.videoDestination = root.videoDestination || root.videoDir
    root.requestVideoPreview()
    Qt.callLater(function() { videoDialog.forceActiveFocus() })
  }
  function requestVideoDialog() {
    if (root.videoBusy || root.pendingVideoDialog) return
    if (!engine.running) { root.status("Build the engine before opening video export"); return }
    // Wait for the engine snapshot so an edit made just before opening is included.
    root.pendingVideoDialog = true
    root.send({ cmd: "dump" })
  }
  function closeVideoDialog() {
    if (root.videoBusy) { root.status("Export continues in the background"); root.close(); return }
    root.previewRestartPending = false
    previewProcess.running = false
    root.videoDialogOpen = false
    root.videoPreviewExpanded = false
    root.videoInstallPrompt = false
    root.clearVideoPreview()
    keys.forceActiveFocus()
  }
  function beginVideoExport() {
    if (root.videoBusy) return
    root.videoJobId = root.nextVideoJobId()
    root.pendingVideoOutputPath = root.videoOutputForJob()
    root.videoOutputFolder = String(root.videoDestination || root.videoDir).trim().replace(/\/+$/, "") || root.videoDir
    if (root.videoOutputFolder.indexOf("~/") === 0) root.videoOutputFolder = Quickshell.env("HOME") + root.videoOutputFolder.slice(1)
    var job = root.videoJobObject(root.videoJobId)
    job.outputPath = root.pendingVideoOutputPath
    root.pendingVideoJson = JSON.stringify(job)
    root.videoBusy = true
    root.videoComplete = false
    root.videoCancelRequested = false
    root.videoInstallPrompt = false
    root.videoProgress = 0
    root.videoStatus = "Starting local render…"
    videoProcess.running = true
  }
  function startVideoExport() {
    if (root.videoBusy) return
    if (ffmpegProbe.running || ffmpegInstall.running) return
    if (root.videoRepetitions < 1 || root.videoRepetitions > 64) { root.videoStatus = "Repetitions must be between 1 and 64"; return }
    root.videoStatus = "Checking FFmpeg encoders…"
    root.videoInstallPrompt = false
    ffmpegProbe.running = true
  }
  function installFfmpeg() {
    if (root.videoBusy || ffmpegProbe.running || ffmpegInstall.running) return
    ffmpegInstall.running = true
  }
  function cancelVideoExport() {
    if (!root.videoBusy) return
    root.videoCancelRequested = true
    root.videoStatus = "Cancelling…"
    videoProcess.write(JSON.stringify({ cmd: "cancel", jobId: root.videoJobId }) + "\n")
  }
  function openVideo() {
    if (!root.videoComplete) return
    root.fileProbePurpose = "open"
    fileProbe.running = true
  }
  function openVideoFolder() {
    if (!root.videoComplete) return
    openFolderProc.running = true
  }
  function sendViaLocalSend() {
    if (!root.videoComplete) return
    root.localSendTarget = root.videoOutputPath
    root.fileProbePurpose = "send"
    fileProbe.running = true
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

  // ---- theme is the loop ----
  // A theme is not just a tone: it composes. The palette is reduced to four
  // musical features and a seed, and the engine writes a loop in the style
  // they imply. Same theme, same loop, every time, so a theme's sound is a
  // fact you can share. Switching theme autosaves the outgoing loop first.
  readonly property string paletteKey: String(accent) + String(background) + String(foreground) + String(urgent) + String(muted)
  property string lastPaletteKey: ""
  property bool pendingGenerate: false
  property int variant: 0
  function paletteFeatures() {
    var a = root.accent, b = root.background, u = root.urgent
    var hue = a.hslHue < 0 ? 0.5 : a.hslHue
    var h = 0
    for (var i = 0; i < root.paletteKey.length; i++) h = (Math.imul(h, 16777619) ^ root.paletteKey.charCodeAt(i)) >>> 0
    return {
      seed: (h + root.variant * 7919) >>> 0,
      energy: 0.6 * a.hslSaturation + 0.4 * Math.abs(a.hslLightness - b.hslLightness),
      warmth: (Math.cos((hue * 360 - 30) * Math.PI / 180) + 1) / 2,
      brightness: b.hslLightness,
      spice: u.hslSaturation
    }
  }
  function generateFromTheme() {
    if (!engine.running) { root.pendingGenerate = true; return }
    var f = paletteFeatures()
    send({ cmd: "save", name: "before theme switch" })
    send({ cmd: "generate", seed: f.seed, energy: f.energy, warmth: f.warmth, brightness: f.brightness, spice: f.spice })
    applyTheme()
    root.status("New loop for " + (root.themeName || "this theme") + (root.variant > 0 ? " (variation " + root.variant + ")" : ""))
  }
  function nextVariation() { root.variant += 1; generateFromTheme() }
  Timer { id: themeSettle; interval: 350; onTriggered: { root.variant = 0; root.generateFromTheme() } }
  onPaletteKeyChanged: {
    var first = root.lastPaletteKey === ""
    root.lastPaletteKey = root.paletteKey
    if (first) applyTheme()
    else themeSettle.restart()
    if (root.videoDialogOpen && !root.videoBusy) root.requestVideoPreview()
  }

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
  function transposeNote(rowIdx, col, dir) {
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
  ////////////////////////////////////////////////////////////////////////////
  // Loop links and saved loops
  //
  // This section copies and loads links and opens the saved-loop library.
  // Keep one clipboard request pending until the engine returns its share code.
  ////////////////////////////////////////////////////////////////////////////
  Process {
    id: copyProc
    onExited: function(code, exitStatus) {
      if (code === 0 && exitStatus === 0)
        root.status("Loop link copied. Paste it anywhere; Ctrl+V here loads one.")
      else
        root.status("Could not copy the loop link. Check that wl-copy and the Wayland clipboard are available.")
    }
  }
  Process {
    id: pasteProc
    running: false
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadShared(String(text || ""))
    }
  }
  function copyLink() {
    if (!engine.running) { root.status("Build the engine before copying a loop link"); return }
    if (copyProc.running || root.copyLinkPending) return
    root.copyLinkPending = true
    root.send({ cmd: "code" })
  }
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
    if (root.videoDialogOpen) {
      if (k === Qt.Key_Escape) { root.closeVideoDialog(); event.accepted = true; return }
      event.accepted = false
      return
    }
    event.accepted = true
    if (root.shareMenuOpen) {
      root.shareMenuOpen = false
      if (k === Qt.Key_Escape) return
    }
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
    if (k === Qt.Key_BracketLeft) { transposeNote(root.cursorRow, root.cursorCol, -1); return }
    if (k === Qt.Key_BracketRight) { transposeNote(root.cursorRow, root.cursorCol, 1); return }
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
      if (k === Qt.Key_G && shift) { nextVariation(); return }
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
  readonly property int sheetW: videoDialogOpen ? 700 : (24 + labelW + 16 * (cellW + gap) + 8)
  readonly property int sheetH: videoDialogOpen ? (videoPreviewExpanded ? 500 : Math.max(255, videoDialogContent.implicitHeight + 24))
                                : (46 + rows.length * (cellH + gap) + 34 + 12)

  PanelWindow {
    id: window
    visible: (root.opened || slide.running) && !root.sessionLocked
    anchors { top: true; left: false; right: false; bottom: false }
    implicitWidth: root.sheetW
    implicitHeight: root.sheetH
    color: "transparent"
    WlrLayershell.namespace: "omaloop"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: sheet
      width: parent.width
      height: parent.height
      y: root.opened ? 0 : -root.sheetH
      color: root.background
      border.color: root.tint(root.accent, 0.35)
      border.width: 1
      radius: Commons.Style.cornerRadius
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
              font.family: Commons.Style.fontFamily
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
                font.family: Commons.Style.fontFamily
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
              font.family: Commons.Style.fontFamily
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
                font.family: Commons.Style.fontFamily
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
              font.family: Commons.Style.fontFamily
            }
          }
        }
      }

      //////////////////////////////////////////////////////////////////////////
      // Share menu
      //
      // The menu overlays the grid below Share so opening it leaves the
      // resting layout in place. Clicking outside dismisses it.
      //////////////////////////////////////////////////////////////////////////
      Item {
        anchors.fill: parent
        visible: root.shareMenuOpen
        z: 10

        MouseArea { anchors.fill: parent; onClicked: root.shareMenuOpen = false }

        Rectangle {
          x: panelContent.x + headerActions.x + shareControl.x - 8
          y: panelContent.y + headerActions.y + shareControl.y + shareControl.height + 4
          width: 164
          height: choices.implicitHeight + 10
          radius: 7
          color: Qt.tint(root.background, root.tint(root.foreground, 0.04))
          border.color: root.tint(root.accent, 0.55)

          Column {
            id: choices
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 5

            Repeater {
              model: ["Copy loop link", "Export video"]
              delegate: Rectangle {
                required property int index
                required property string modelData
                width: choices.width
                height: 28
                radius: 4
                color: menuAction.containsMouse ? root.tint(root.accent, 0.12) : "transparent"

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: 9
                  anchors.verticalCenter: parent.verticalCenter
                  text: parent.modelData
                  color: root.foreground
                  font.pixelSize: 12
                  font.family: Commons.Style.fontFamily
                }
                MouseArea {
                  id: menuAction
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.shareMenuOpen = false
                    if (parent.index === 0) root.copyLink()
                    else root.requestVideoDialog()
                  }
                }
              }
            }
          }
        }
      }

      //////////////////////////////////////////////////////////////////////////////
      // Video export dialog
      //
      // The dialog groups the preview, export settings, and render controls.
      // The status wraps beside the controls so long errors stay readable.
      //////////////////////////////////////////////////////////////////////////////
      Rectangle {
        id: videoDialog
        readonly property real labelWidth: Math.max(58, socialHandleLabel.implicitWidth)
        visible: root.videoDialogOpen
        z: 20
        anchors.fill: parent
        color: root.background
        border.color: root.tint(root.accent, 0.65)
        border.width: 1
        radius: Commons.Style.cornerRadius
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.videoPreviewExpanded) expandedPreview.dismiss()
            else root.closeVideoDialog()
            event.accepted = true
          }
        }

        Column {
          id: videoDialogContent
          visible: !root.videoPreviewExpanded
          anchors.fill: parent
          anchors.margins: 12
          spacing: 8

          Item {
            width: parent.width
            height: 24
            Text { anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; text: "Export video"; color: root.foreground; font.bold: true; font.pixelSize: 16; font.family: Commons.Style.fontFamily }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "×"
              color: root.foreground
              font.pixelSize: 20
              MouseArea { anchors.fill: parent; anchors.margins: -5; onClicked: root.closeVideoDialog() }
            }
          }

          Row {
            width: parent.width
            spacing: 16

            Rectangle {
              width: 180
              height: 175
              radius: 6
              color: root.tint(root.foreground, 0.05)
              border.color: root.tint(root.accent, 0.35)
              Image {
                id: previewImage
                anchors.fill: parent
                anchors.margins: 6
                source: !root.previewReady || root.previewPath === "" ? "" : "file://" + root.previewPath
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }
              Controls.AbstractButton {
                anchors.fill: parent
                enabled: previewImage.status === Image.Ready
                Accessible.name: "Expand preview"
                HoverHandler { cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }
                onClicked: {
                  root.videoPreviewExpanded = true
                  expandedPreview.forceActiveFocus()
                }
              }
              Text {
                anchors.centerIn: parent
                visible: !root.previewReady || previewImage.status === Image.Error
                text: root.videoBusy ? "Rendering…" : "Preview"
                color: root.foreground
                font.pixelSize: 12
                font.family: Commons.Style.fontFamily
              }
            }

            Column {
              width: parent.width - 196
              spacing: 8

              Row {
                spacing: 8
                Text { text: "aspect"; width: videoDialog.labelWidth; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                Repeater {
                  model: ["portrait", "square", "landscape"]
                  delegate: Rectangle {
                    required property string modelData
                    width: 102; height: 27; radius: 4
                    color: root.videoAspect === modelData ? root.accent : root.tint(root.foreground, 0.08)
                    Text { anchors.centerIn: parent; text: modelData; color: root.videoAspect === modelData ? root.background : root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily }
                    MouseArea { anchors.fill: parent; onClicked: { root.videoAspect = modelData; root.requestVideoPreview() } }
                  }
                }
              }

              Row {
                spacing: 8
                Text { text: "repeats"; width: videoDialog.labelWidth; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "−"; color: root.foreground; font.pixelSize: 18; MouseArea { anchors.fill: parent; anchors.margins: -5; onClicked: { root.invalidateVideoResult(); root.videoRepetitions = Math.max(1, root.videoRepetitions - 1) } } }
                Text { text: root.videoRepetitions + "  (" + root.durationLabel() + ")"; color: root.foreground; font.pixelSize: 12; font.family: Commons.Style.fontFamily; width: 120; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "+"; color: root.foreground; font.pixelSize: 18; MouseArea { anchors.fill: parent; anchors.margins: -5; onClicked: { root.invalidateVideoResult(); root.videoRepetitions = Math.min(64, root.videoRepetitions + 1) } } }
              }

              Row {
                width: parent.width
                spacing: 8
                Text { id: socialHandleLabel; text: "social handle"; width: videoDialog.labelWidth; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                Rectangle {
                  width: parent.width - videoDialog.labelWidth - parent.spacing; height: 27; radius: 4
                  color: root.tint(root.foreground, 0.08)
                  border.color: handleField.activeFocus ? root.accent : "transparent"
                  TextInput {
                    id: handleField
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.foreground
                    font.pixelSize: 11
                    font.family: Commons.Style.fontFamily
                    maximumLength: 64
                    onTextChanged: { root.videoHandle = text; root.requestVideoPreview() }
                  }
                  Text {
                    anchors.left: handleField.left
                    anchors.verticalCenter: handleField.verticalCenter
                    visible: handleField.length === 0 && !handleField.inputMethodComposing
                    text: "@example"
                    color: root.foreground
                    font: handleField.font
                  }
                }
              }


              Row {
                width: parent.width
                spacing: 8
                Text { text: "save to"; width: videoDialog.labelWidth; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; anchors.verticalCenter: parent.verticalCenter }
                Rectangle {
                  width: parent.width - videoDialog.labelWidth - parent.spacing; height: 27; radius: 4
                  color: root.tint(root.foreground, 0.08)
                  border.color: destinationField.activeFocus ? root.accent : "transparent"
                  TextInput {
                    id: destinationField
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: activeFocus ? root.foreground : "transparent"
                    font.pixelSize: 11
                    font.family: Commons.Style.fontFamily
                    text: root.videoDestination
                    maximumLength: 512
                    onTextChanged: { root.invalidateVideoResult(); root.videoDestination = text }
                  }
                  Text {
                    anchors.fill: destinationField
                    verticalAlignment: Text.AlignVCenter
                    visible: !destinationField.activeFocus
                    text: destinationField.text
                    color: root.foreground
                    font: destinationField.font
                    elide: Text.ElideLeft
                  }
                }
              }


              Item {
                x: videoDialog.labelWidth + parent.spacing
                width: parent.width - x
                height: Math.max(27, renderStatus.implicitHeight)
                Text {
                  id: renderStatus
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - 12 - (root.videoBusy ? renderProgress.width
                    : root.videoComplete ? completedActions.width : renderButton.width)
                  text: root.videoStatus === "" ? "MP4 · H.264 · yuv420p · AAC · 30 fps" : root.videoStatus
                  color: root.foreground
                  wrapMode: Text.Wrap
                  font.pixelSize: 10
                  font.family: Commons.Style.fontFamily
                }
                Row {
                  id: renderProgress
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 10
                  visible: root.videoBusy
                  Rectangle {
                    width: 120; height: 8; radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.tint(root.foreground, 0.12)
                    Rectangle { width: parent.width * root.videoProgress; height: parent.height; radius: 4; color: root.accent }
                  }
                  Text {
                    text: "Cancel"; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily
                    MouseArea { anchors.fill: parent; anchors.margins: -5; onClicked: root.cancelVideoExport() }
                  }
                }
                Text {
                  id: renderButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !root.videoBusy && !root.videoComplete
                  text: "Render video"; color: root.background
                  font.bold: true; font.pixelSize: 11; font.family: Commons.Style.fontFamily
                  leftPadding: 10; rightPadding: 10; topPadding: 5; bottomPadding: 5
                  Rectangle { anchors.fill: parent; z: -1; radius: 4; color: root.accent }
                  MouseArea { anchors.fill: parent; onClicked: root.startVideoExport() }
                }

                Row {
                  id: completedActions
                  anchors.right: parent.right
                  visible: root.videoComplete && !root.videoBusy
                  spacing: 14
                  anchors.verticalCenter: parent.verticalCenter
                  Text { text: "Open video"; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: root.openVideo() } }
                  Text { text: "Open folder"; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: root.openVideoFolder() } }
                  Text { text: "Send via LocalSend"; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; MouseArea { anchors.fill: parent; anchors.margins: -4; onClicked: root.sendViaLocalSend() } }
                }
              }

            }
          }

        }

        //////////////////////////////////////////////////////////////////////////////
        // Expanded video preview
        //
        // The full-size frame fits inside the compact panel. The export
        // dialog stays underneath so closing the preview restores its settings.
        //////////////////////////////////////////////////////////////////////////////
        FocusScope {
          id: expandedPreview
          z: 2
          anchors.fill: parent
          anchors.margins: 12
          visible: root.videoPreviewExpanded

          function dismiss() {
            root.videoPreviewExpanded = false
            videoDialog.forceActiveFocus()
          }

          component PreviewButton: Controls.Button {
            implicitHeight: 30
            leftPadding: 12
            rightPadding: 12
            font.family: Commons.Style.fontFamily
            font.pixelSize: 12
            contentItem: Text {
              text: parent.text
              font: parent.font
              color: root.foreground
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
              radius: 4
              color: root.tint(root.foreground, parent.down ? 0.18 : 0.08)
              border.color: parent.visualFocus || parent.hovered ? root.accent : root.tint(root.foreground, 0.22)
            }
          }

          Item {
            id: previewToolbar
            width: parent.width
            height: 30
            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Video preview" + (expandedFrame.status === Image.Ready
                                       ? "  ·  " + expandedFrame.sourceSize.width + " × " + expandedFrame.sourceSize.height
                                       : "")
              color: root.foreground
              font.bold: true
              font.pixelSize: 14
              font.family: Commons.Style.fontFamily
            }
            PreviewButton {
              anchors.right: parent.right
              text: "Close"
              onClicked: expandedPreview.dismiss()
            }
          }

          Rectangle {
            anchors.top: previewToolbar.bottom
            anchors.topMargin: 8
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            color: root.tint(root.foreground, 0.045)

            Image {
              id: expandedFrame
              anchors.fill: parent
              source: expandedPreview.visible ? previewImage.source : ""
              asynchronous: true
              fillMode: Image.PreserveAspectFit
              mipmap: true
            }
          }
        }

        Rectangle {
          visible: root.videoInstallPrompt
          z: 3
          anchors.centerIn: parent
          width: 420
          height: 170
          radius: 8
          color: root.background
          border.color: root.urgent
          border.width: 1
          Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10
            Text { text: "FFmpeg is missing or incompatible"; color: root.foreground; font.bold: true; font.pixelSize: 13; font.family: Commons.Style.fontFamily }
            Text { width: parent.width; wrapMode: Text.WordWrap; text: "Video export needs an existing FFmpeg with software libx264 and AAC encoders. Install ffmpeg now in a visible Omarchy terminal? No install happens unless you confirm."; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily }
            Row {
              spacing: 16
              Text { text: "Cancel"; color: root.foreground; font.pixelSize: 11; font.family: Commons.Style.fontFamily; MouseArea { anchors.fill: parent; anchors.margins: -5; onClicked: { root.videoInstallPrompt = false; root.videoStatus = "Install declined; existing features are unchanged" } } }
              Text {
                text: "Install ffmpeg"
                color: root.background
                font.bold: true
                font.pixelSize: 11
                font.family: Commons.Style.fontFamily
                leftPadding: 10; rightPadding: 10; topPadding: 5; bottomPadding: 5
                Rectangle { anchors.fill: parent; z: -1; radius: 4; color: root.accent }
                MouseArea { anchors.fill: parent; onClicked: root.installFfmpeg() }
              }
            }
          }
        }
      }

      Column {
        id: panelContent
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
              font.family: Commons.Style.fontFamily
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: (root.themeName !== "" ? "sounds like " + root.themeName + " · " : "") + root.keyName
              color: root.foreground
              opacity: 0.55
              font.pixelSize: 11
              font.family: Commons.Style.fontFamily
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
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11

            // preset
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.preset
              color: root.foreground
              font.pixelSize: 12
              font.family: Commons.Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.nextPreset() }
            }
            // bpm
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: 4
              Text { text: "−"; color: root.foreground; opacity: 0.6; font.pixelSize: 13; font.family: Commons.Style.fontFamily
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.setBpm(root.bpm - 1) } }
              Text { text: Math.round(root.bpm) + " bpm"; color: root.foreground; font.pixelSize: 12; font.family: Commons.Style.fontFamily }
              Text { text: "+"; color: root.foreground; opacity: 0.6; font.pixelSize: 13; font.family: Commons.Style.fontFamily
                MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.setBpm(root.bpm + 1) } }
            }
            // swing
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "swing " + Math.round(root.swing * 100) + "%"
              color: root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Commons.Style.fontFamily
              MouseArea {
                anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                onClicked: root.setSwing(root.swing >= 0.6 ? 0 : root.swing + 0.1)
                onWheel: function(w) { root.setSwing(root.swing + (w.angleDelta.y > 0 ? 0.05 : -0.05)) }
              }
            }
            // share
            Text {
              anchors.verticalCenter: parent.verticalCenter
              id: shareControl
              text: "share"
              color: root.shareMenuOpen ? root.accent : root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Commons.Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: { root.closeLibrary(); root.shareMenuOpen = true } }
            }
            // library
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "library"
              color: root.libraryOpen ? root.accent : root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Commons.Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.libraryOpen ? root.closeLibrary() : root.openLibrary(false) }
            }
            // legacy WAV export (Shift+E remains unchanged)
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "export"
              color: root.foreground
              opacity: 0.8
              font.pixelSize: 12
              font.family: Commons.Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.exportLoop() }
            }
            // stop
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰓛"
              color: root.urgent
              opacity: root.playing ? 1 : 0.3
              font.pixelSize: 15
              font.family: Commons.Style.fontFamily
              Behavior on opacity { NumberAnimation { duration: 120 } }
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.stop() }
            }
            // play / pause
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.playing ? "󰏤" : "󰐊"
              color: root.playing ? root.accent : root.foreground
              font.pixelSize: 15
              font.family: Commons.Style.fontFamily
              MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.togglePlay() }
            }
            // close
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰅖"
              color: root.foreground
              font.pixelSize: 16
              font.family: Commons.Style.fontFamily
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
                  font.family: Commons.Style.fontFamily
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
                    font.family: Commons.Style.fontFamily
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.cursorRow = rowItem.index; root.cursorCol = cell.index; root.toggleCell(rowItem.index, cell.index) }
                    onWheel: function(w) {
                      root.cursorRow = rowItem.index; root.cursorCol = cell.index
                      root.transposeNote(rowItem.index, cell.index, w.angleDelta.y > 0 ? 1 : -1)
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
            font.family: Commons.Style.fontFamily
            text: root.engineState === "missing" ? "Engine not built yet: click Build (needs cargo) or run install.sh"
                : root.engineState === "building" ? "Building engine… " + root.lastErr
                : root.engineState === "error" ? (root.statusText || "Engine error: " + root.lastErr)
                : root.statusText !== "" ? root.statusText
                : "Space play · arrows · Enter toggle · Q-P A-H steps · [ ] note · , . bpm · ; ' swing · S-P preset · S-R random · S-E export · S-G new loop from theme · C-C link · C-V paste · C-S save · C-O library · Esc"
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.engineState === "missing" || root.engineState === "error"
            text: root.engineState === "missing" ? "Build" : "Retry"
            color: root.background
            font.pixelSize: 11
            font.bold: true
            font.family: Commons.Style.fontFamily
            leftPadding: 10; rightPadding: 10; topPadding: 3; bottomPadding: 3
            Rectangle { anchors.fill: parent; z: -1; radius: Commons.Style.cornerRadius; color: root.accent }
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
            font.family: Commons.Style.fontFamily
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
