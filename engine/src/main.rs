//! omaloop engine: a 16-step groovebox that speaks JSON lines on stdin/stdout.
//!
//! Six tracks. Four synthesized drums (kick, snare, hat, ohat) and two note
//! tracks (bass: saw+sub with a snappy filter; lead: three detuned saws, a nod
//! to FruityLoops' 3xOSC, into a dotted-eighth delay). No samples.
//!
//! stdin  <- {"cmd":"play"} | {"cmd":"stop"} | {"cmd":"toggle"}
//!           {"cmd":"bpm","value":138}        {"cmd":"swing","value":0.2}
//!           {"cmd":"volume","value":0.8}
//!           {"cmd":"step","track":"kick","index":0,"on":true}
//!           {"cmd":"note","track":"lead","index":0,"note":57}   (MIDI, 0 = rest)
//!           {"cmd":"tone","cutoff":0.4,"detune":0.6,"drive":0.3,"sub":0.5}
//!           {"cmd":"clear","track":"lead"}   {"cmd":"random","track":"bass"}
//!           {"cmd":"preset","name":"acid"}   {"cmd":"load", ...pattern fields}
//!           {"cmd":"generate","seed":123,"energy":0.7,"warmth":0.3,"brightness":0.1,"spice":0.5}
//!           {"cmd":"load","code":"<loop code>"}   {"cmd":"code"}
//!           {"cmd":"save","name":"my loop"}  {"cmd":"open","name":"my loop"}
//!           {"cmd":"delete","name":"my loop"} {"cmd":"list"}
//!           {"cmd":"export","path":"/tmp/x.wav","bars":4}
//!           {"cmd":"dump"}
//! stdout -> {"event":"step","index":n}   {"event":"state",...}
//!           {"event":"code","code":..}      {"event":"library","names":[..]}
//!           {"event":"exported","path":..}  {"event":"error","message":..}
//!
//! Loop code: 48 bytes, base64url. v1 layout: [0]=1, [1..9)=4 drum masks u16 LE,
//! [9..41)=32 MIDI notes (bass then lead), [41]=bpm-40, [42]=swing, [43..47)=
//! cutoff detune drive sub (all x255), [47]=transpose semitones 0-11.
//!
//! `--state <file>` loads the pattern at start and saves it after every change.
//! Saved patterns live next to it in `patterns/<name>.json`.
//! `--render out.wav --bars N [--preset acid | --code <loop code>]` renders offline.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::f32::consts::PI;
use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;

const STEPS: usize = 16;
const DRUMS: [&str; 4] = ["kick", "snare", "hat", "ohat"];
const NOTE_TRACKS: [&str; 2] = ["bass", "lead"];
const PRESETS: [&str; 4] = ["y2k", "acid", "minimal", "breaks"];
/// A minor pentatonic plus the 2nd and 6th: enough colour, never wrong.
const SCALE: [u8; 7] = [0, 2, 3, 5, 7, 8, 10];
const MAJOR: [u8; 7] = [0, 2, 4, 5, 7, 9, 11];
const DORIAN: [u8; 7] = [0, 2, 3, 5, 7, 9, 10];
const DELAY_MAX: usize = 96_000;

#[derive(Clone)]
struct Pattern {
    drums: [[bool; STEPS]; 4],
    notes: [[u8; STEPS]; 2],
    bpm: f32,
    swing: f32,
    volume: f32,
    cutoff: f32,
    detune: f32,
    drive: f32,
    sub: f32,
    transpose: u8,
    preset: String,
}

impl Pattern {
    fn blank(name: &str, bpm: f32) -> Self {
        Pattern {
            drums: [[false; STEPS]; 4],
            notes: [[0; STEPS]; 2],
            bpm,
            swing: 0.0,
            volume: 0.8,
            cutoff: 0.45,
            detune: 0.5,
            drive: 0.2,
            sub: 0.5,
            transpose: 0,
            preset: name.to_string(),
        }
    }

    fn preset(name: &str) -> Option<Self> {
        let mut p = match name {
            "y2k" => Pattern::blank(name, 138.0),
            "acid" => Pattern::blank(name, 132.0),
            "minimal" => Pattern::blank(name, 126.0),
            "breaks" => Pattern::blank(name, 165.0),
            _ => return None,
        };
        let four = |p: &mut Pattern| {
            for i in (0..STEPS).step_by(4) {
                p.drums[0][i] = true;
            }
        };
        match name {
            "y2k" => {
                four(&mut p);
                p.drums[1][4] = true;
                p.drums[1][12] = true;
                for i in (2..STEPS).step_by(4) {
                    p.drums[2][i] = true;
                }
                p.notes[0] = [45, 0, 45, 45, 0, 45, 0, 48, 45, 0, 45, 45, 0, 43, 0, 43];
                p.notes[1] = [57, 0, 57, 0, 60, 0, 57, 0, 64, 0, 62, 0, 60, 0, 59, 0];
                p.swing = 0.1;
            }
            "acid" => {
                four(&mut p);
                p.drums[1][4] = true;
                p.drums[1][12] = true;
                for i in (2..STEPS).step_by(4) {
                    p.drums[3][i] = true;
                }
                p.notes[0] = [45, 45, 57, 45, 48, 45, 45, 57, 45, 45, 60, 45, 48, 45, 43, 45];
                p.cutoff = 0.35;
                p.drive = 0.5;
                p.swing = 0.18;
            }
            "minimal" => {
                four(&mut p);
                for i in (2..STEPS).step_by(4) {
                    p.drums[2][i] = true;
                }
                p.drums[3][14] = true;
                p.notes[0] = [33, 0, 0, 0, 0, 0, 33, 0, 0, 0, 33, 0, 0, 0, 0, 0];
                p.notes[1] = [0, 0, 0, 0, 0, 0, 0, 69, 0, 0, 0, 0, 0, 0, 67, 0];
                p.cutoff = 0.25;
                p.sub = 0.8;
            }
            "breaks" => {
                p.drums[0] = [true, false, false, false, false, false, true, false, false, false, true, false, false, false, false, false];
                p.drums[1] = [false, false, false, false, true, false, false, false, false, false, false, false, true, false, false, true];
                p.drums[2] = [true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false];
                p.drums[3][15] = true;
                p.notes[0] = [33, 0, 0, 33, 0, 0, 33, 0, 0, 0, 33, 0, 0, 36, 0, 0];
                p.notes[1] = [0, 0, 0, 0, 0, 0, 0, 0, 69, 0, 72, 0, 0, 0, 0, 0];
                p.cutoff = 0.6;
                p.detune = 0.8;
            }
            _ => {}
        }
        Some(p)
    }

    fn to_json(&self, playing: bool) -> Value {
        json!({
            "event": "state",
            "playing": playing,
            "preset": self.preset,
            "bpm": self.bpm, "swing": self.swing, "volume": self.volume,
            "cutoff": self.cutoff, "detune": self.detune, "drive": self.drive, "sub": self.sub,
            "transpose": self.transpose,
            "kick": self.drums[0], "snare": self.drums[1], "hat": self.drums[2], "ohat": self.drums[3],
            "bass": self.notes[0], "lead": self.notes[1],
        })
    }

    /// Apply any subset of pattern fields from a JSON object (load / state file).
    fn merge(&mut self, v: &Value) {
        for (i, name) in DRUMS.iter().enumerate() {
            if let Some(arr) = v[name].as_array() {
                for (j, x) in arr.iter().take(STEPS).enumerate() {
                    self.drums[i][j] = x.as_bool().unwrap_or(false);
                }
            }
        }
        for (i, name) in NOTE_TRACKS.iter().enumerate() {
            if let Some(arr) = v[name].as_array() {
                for (j, x) in arr.iter().take(STEPS).enumerate() {
                    self.notes[i][j] = x.as_u64().unwrap_or(0).min(127) as u8;
                }
            }
        }
        let f = |k: &str, cur: f32, lo: f32, hi: f32| v[k].as_f64().map(|x| (x as f32).clamp(lo, hi)).unwrap_or(cur);
        self.bpm = f("bpm", self.bpm, 40.0, 300.0);
        self.swing = f("swing", self.swing, 0.0, 1.0);
        self.volume = f("volume", self.volume, 0.0, 1.0);
        self.cutoff = f("cutoff", self.cutoff, 0.0, 1.0);
        self.detune = f("detune", self.detune, 0.0, 1.0);
        self.drive = f("drive", self.drive, 0.0, 1.0);
        self.sub = f("sub", self.sub, 0.0, 1.0);
        if let Some(t) = v["transpose"].as_u64() {
            self.transpose = (t % 12) as u8;
        }
        if let Some(s) = v["preset"].as_str() {
            self.preset = s.to_string();
        }
    }

    fn to_code(&self) -> String {
        let mut b = Vec::with_capacity(48);
        b.push(1u8);
        for d in &self.drums {
            let mask = d.iter().enumerate().fold(0u16, |m, (i, on)| if *on { m | (1 << i) } else { m });
            b.extend_from_slice(&mask.to_le_bytes());
        }
        for t in &self.notes {
            b.extend_from_slice(t);
        }
        b.push((self.bpm.round() as i32 - 40).clamp(0, 255) as u8);
        for v in [self.swing, self.cutoff, self.detune, self.drive, self.sub] {
            b.push((v * 255.0).round() as u8);
        }
        b.push(self.transpose % 12);
        base64url(&b)
    }

    fn from_code(code: &str) -> Result<Self, String> {
        let b = base64url_decode(code.trim())?;
        if b.len() < 48 || b[0] != 1 {
            return Err("not an omaloop v1 loop code".into());
        }
        let mut p = Pattern::blank("shared", 138.0);
        for (t, d) in p.drums.iter_mut().enumerate() {
            let mask = u16::from_le_bytes([b[1 + t * 2], b[2 + t * 2]]);
            for (i, on) in d.iter_mut().enumerate() {
                *on = mask & (1 << i) != 0;
            }
        }
        for (t, notes) in p.notes.iter_mut().enumerate() {
            for (i, n) in notes.iter_mut().enumerate() {
                *n = b[9 + t * STEPS + i].min(127);
            }
        }
        p.bpm = 40.0 + b[41] as f32;
        let f = |x: u8| x as f32 / 255.0;
        p.swing = f(b[42]);
        p.cutoff = f(b[43]);
        p.detune = f(b[44]);
        p.drive = f(b[45]);
        p.sub = f(b[46]);
        p.transpose = b[47] % 12;
        Ok(p)
    }
}

/// Small deterministic RNG so a theme always composes the same loop.
struct Rng(u64);
impl Rng {
    fn new(seed: u64) -> Self { Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1) }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn f(&mut self) -> f32 { (self.next() >> 40) as f32 / (1u64 << 24) as f32 }
    fn chance(&mut self, p: f32) -> bool { self.f() < p }
    fn pick<T: Copy>(&mut self, xs: &[T]) -> T { xs[(self.next() % xs.len() as u64) as usize] }
    fn range(&mut self, lo: f32, hi: f32) -> f32 { lo + (hi - lo) * self.f() }
}

/// Compose a loop from a palette fingerprint. `energy` (saturation, contrast),
/// `warmth` (hue: orange high, blue low), `brightness` (background lightness),
/// and `spice` (second-colour saturation) pick a style; the seed picks the
/// specific notes inside that style's rules.
impl Pattern {
    fn generate(seed: u64, energy: f32, warmth: f32, brightness: f32, spice: f32) -> Self {
        let mut r = Rng::new(seed);
        let style = if brightness >= 0.5 { "house" }
            else if energy > 0.6 && warmth < 0.5 { "techno" }
            else if energy > 0.6 { "synthwave" }
            else if warmth >= 0.5 { "boombap" }
            else { "deep" };
        let mut p = Pattern::blank(style, 120.0);
        let (scale, bass_root, lead_root): (&[u8], u8, u8) = match style {
            "house" => (&MAJOR, 33, 57),
            "boombap" => (&DORIAN, 33, 57),
            _ => (&SCALE, 33, 57),
        };
        let every = |p: &mut Pattern, t: usize, start: usize, step: usize| {
            let mut i = start;
            while i < STEPS { p.drums[t][i] = true; i += step; }
        };
        match style {
            "techno" => {
                p.bpm = r.range(132.0, 142.0).round();
                p.swing = r.range(0.0, 0.12);
                every(&mut p, 0, 0, 4);
                if r.chance(0.5) { p.drums[1][4] = true; p.drums[1][12] = true; }
                every(&mut p, 3, 2, 4);
                for i in 0..STEPS { if i % 2 == 1 && r.chance(0.35 + energy * 0.4) { p.drums[2][i] = true; } }
                if r.chance(0.5) { p.drums[2][15] = true; }
                let fifth = scale[4];
                for i in 0..STEPS {
                    p.notes[0][i] = if i % 2 == 0 { bass_root } else if r.chance(0.3) { bass_root + fifth } else if r.chance(0.5) { bass_root } else { 0 };
                }
                let motif = [r.pick(scale), r.pick(scale), r.pick(scale)];
                for (k, i) in [0usize, 6, 10, 14].iter().enumerate() {
                    if r.chance(0.3 + spice * 0.5) { p.notes[1][*i] = lead_root + 12 + motif[k % 3]; }
                }
                p.cutoff = 0.35; p.drive = 0.35; p.sub = 0.8;
            }
            "synthwave" => {
                p.bpm = r.range(116.0, 128.0).round();
                p.swing = 0.0;
                every(&mut p, 0, 0, 4);
                p.drums[1][4] = true; p.drums[1][12] = true;
                every(&mut p, 2, 0, 2);
                every(&mut p, 3, 2, 8);
                for i in 0..STEPS { p.notes[0][i] = if i % 4 == 3 { bass_root + 12 } else { bass_root }; }
                let chord = [scale[0], scale[2], scale[4], scale[6]];
                let up = r.chance(0.6);
                for i in 0..STEPS {
                    let k = if up { i % 4 } else { 3 - i % 4 };
                    p.notes[1][i] = if r.chance(0.85) { lead_root + 12 + chord[k] } else { 0 };
                }
                p.cutoff = 0.6; p.detune = 0.85; p.drive = 0.25; p.sub = 0.5;
            }
            "boombap" => {
                p.bpm = r.range(86.0, 96.0).round();
                p.swing = r.range(0.28, 0.45);
                p.drums[0][0] = true;
                p.drums[0][r.pick(&[6usize, 7, 10])] = true;
                if r.chance(0.5) { p.drums[0][r.pick(&[9usize, 11, 13])] = true; }
                p.drums[1][4] = true; p.drums[1][12] = true;
                for i in 0..STEPS { if i % 2 == 0 && r.chance(0.8) { p.drums[2][i] = true; } }
                if r.chance(0.6) { p.drums[3][14] = true; }
                p.notes[0][0] = bass_root;
                p.notes[0][r.pick(&[6usize, 7])] = bass_root;
                p.notes[0][r.pick(&[10usize, 11])] = bass_root + r.pick(&[scale[2], scale[4], scale[6]]);
                for _ in 0..3 {
                    let i = (r.next() % STEPS as u64) as usize;
                    p.notes[1][i] = lead_root + 12 + r.pick(scale);
                }
                p.cutoff = 0.3; p.detune = 0.3; p.drive = 0.15; p.sub = 0.7;
            }
            "deep" => {
                p.bpm = r.range(118.0, 126.0).round();
                p.swing = r.range(0.08, 0.2);
                every(&mut p, 0, 0, 4);
                every(&mut p, 2, 2, 4);
                if r.chance(0.4) { p.drums[3][10] = true; }
                if r.chance(0.5) { p.drums[1][4] = true; p.drums[1][12] = true; }
                p.notes[0][0] = bass_root - 12;
                p.notes[0][r.pick(&[6usize, 7, 8])] = bass_root - 12;
                if r.chance(0.6) { p.notes[0][r.pick(&[11usize, 13, 14])] = bass_root - 12 + r.pick(&[scale[2], scale[4]]); }
                let a = lead_root + 12 + r.pick(scale);
                p.notes[1][r.pick(&[7usize, 8])] = a;
                if r.chance(0.5 + spice * 0.5) { p.notes[1][r.pick(&[13usize, 14, 15])] = a + r.pick(&[0u8, 3, 5]); }
                p.cutoff = 0.2; p.detune = 0.4; p.drive = 0.1; p.sub = 1.0;
            }
            _ => {
                p.bpm = r.range(122.0, 128.0).round();
                p.swing = r.range(0.05, 0.15);
                every(&mut p, 0, 0, 4);
                p.drums[1][4] = true; p.drums[1][12] = true;
                every(&mut p, 3, 2, 4);
                for i in 0..STEPS { if i % 2 == 0 && r.chance(0.7) { p.drums[2][i] = true; } }
                let fifth = scale[4];
                for i in 0..STEPS {
                    p.notes[0][i] = match i % 4 { 0 => bass_root, 2 => if r.chance(0.6) { bass_root + fifth } else { 0 }, 3 => if r.chance(0.4) { bass_root + 12 } else { 0 }, _ => 0 };
                }
                let stab = [scale[0], scale[2], scale[4]];
                for i in [2usize, 6, 10, 14] {
                    if r.chance(0.7) { p.notes[1][i] = lead_root + 12 + r.pick(&stab); }
                }
                p.cutoff = 0.7; p.detune = 0.5; p.drive = 0.2; p.sub = 0.4;
            }
        }
        p
    }
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64url(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 4 / 3 + 3);
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |acc, (i, b)| acc | (*b as u32) << (16 - 8 * i));
        for i in 0..chunk.len() + 1 {
            out.push(B64[((n >> (18 - 6 * i)) & 63) as usize] as char);
        }
    }
    out
}

fn base64url_decode(s: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0;
    for c in s.bytes().filter(|c| *c != b'=') {
        let v = B64.iter().position(|x| *x == c).ok_or("bad character in loop code")? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((acc >> bits) & 0xff) as u8);
        }
    }
    Ok(out)
}

fn safe_name(name: &str) -> Option<String> {
    let n: String = name.trim().chars().filter(|c| c.is_alphanumeric() || *c == ' ' || *c == '-' || *c == '_').collect();
    let n = n.trim().to_string();
    if n.is_empty() || n.len() > 48 { None } else { Some(n) }
}

#[derive(Clone, Copy)]
struct Voice {
    age: f32,
    active: bool,
}

const OFF: Voice = Voice { age: 1e9, active: false };

struct Engine {
    pattern: Pattern,
    playing: bool,
    sample_rate: f32,
    step: usize,
    samples_left: f32,
    kick: Voice,
    snare: Voice,
    hat: Voice,
    ohat: Voice,
    bass: Voice,
    bass_freq: f32,
    bass_phase: f32,
    bass_lp: f32,
    lead: Voice,
    lead_freq: f32,
    lead_phase: [f32; 3],
    lead_lp: f32,
    delay: Vec<f32>,
    delay_pos: usize,
    noise: u32,
    events: Option<Sender<Value>>,
    library: Option<std::path::PathBuf>,
}

impl Engine {
    fn new(sample_rate: f32, events: Option<Sender<Value>>) -> Self {
        Engine {
            pattern: Pattern::preset("y2k").unwrap(),
            playing: false,
            sample_rate,
            step: 0,
            samples_left: 0.0,
            kick: OFF,
            snare: OFF,
            hat: OFF,
            ohat: OFF,
            bass: OFF,
            bass_freq: 0.0,
            bass_phase: 0.0,
            bass_lp: 0.0,
            lead: OFF,
            lead_freq: 0.0,
            lead_phase: [0.0; 3],
            lead_lp: 0.0,
            delay: vec![0.0; DELAY_MAX],
            delay_pos: 0,
            noise: 0x1234_5678,
            events,
            library: None,
        }
    }

    fn emit(&self, v: Value) {
        if let Some(tx) = &self.events {
            let _ = tx.send(v);
        }
    }

    fn step_len(&self) -> f32 {
        self.sample_rate * 60.0 / self.pattern.bpm / 4.0
    }

    /// Swing lengthens even 16ths and shortens odd ones; pairs still sum to two steps.
    fn this_step_len(&self) -> f32 {
        let s = self.pattern.swing * 0.5;
        let base = self.step_len();
        if self.step % 2 == 0 { base * (1.0 + s) } else { base * (1.0 - s) }
    }

    fn white(&mut self) -> f32 {
        self.noise ^= self.noise << 13;
        self.noise ^= self.noise >> 17;
        self.noise ^= self.noise << 5;
        (self.noise as f32 / u32::MAX as f32) * 2.0 - 1.0
    }

    fn midi_hz(n: u8) -> f32 {
        440.0 * 2f32.powf((n as f32 - 69.0) / 12.0)
    }

    fn trigger_step(&mut self) {
        let p = self.pattern.clone();
        let on = Voice { age: 0.0, active: true };
        if p.drums[0][self.step] {
            self.kick = on;
        }
        if p.drums[1][self.step] {
            self.snare = on;
        }
        if p.drums[2][self.step] {
            self.hat = on;
            self.ohat = OFF; // closed hat chokes the open hat
        }
        if p.drums[3][self.step] {
            self.ohat = on;
        }
        let b = p.notes[0][self.step];
        if b > 0 {
            self.bass = on;
            self.bass_freq = Self::midi_hz(b + p.transpose);
        }
        let l = p.notes[1][self.step];
        if l > 0 {
            self.lead = on;
            self.lead_freq = Self::midi_hz(l + p.transpose);
        }
        self.emit(json!({"event": "step", "index": self.step}));
    }

    fn next_sample(&mut self) -> f32 {
        if self.playing {
            if self.samples_left <= 0.0 {
                self.trigger_step();
                self.samples_left = self.this_step_len();
            }
            self.samples_left -= 1.0;
            if self.samples_left <= 0.0 {
                self.step = (self.step + 1) % STEPS;
            }
        }
        let dt = 1.0 / self.sample_rate;
        let (sub, cutoff, detune, drive, volume) = {
            let p = &self.pattern;
            (p.sub, p.cutoff, p.detune, p.drive, p.volume)
        };
        let mut dry = 0.0;
        let mut send = 0.0;

        if self.kick.active {
            let t = self.kick.age;
            let f = 48.0 + 110.0 * (-t * 38.0).exp();
            let tail = 6.0 + 6.0 * (1.0 - sub);
            dry += (2.0 * PI * f * t).sin() * (-t * tail).exp() * 0.95;
            self.kick.age += dt;
            self.kick.active = t < 0.7;
        }
        if self.snare.active {
            let t = self.snare.age;
            let n = self.white();
            dry += (n * 0.55 + (2.0 * PI * 185.0 * t).sin() * 0.3) * (-t * 17.0).exp() * 0.6;
            self.snare.age += dt;
            self.snare.active = t < 0.3;
        }
        if self.hat.active {
            let t = self.hat.age;
            let n = self.white();
            dry += n * (-t * 85.0).exp() * 0.22;
            self.hat.age += dt;
            self.hat.active = t < 0.12;
        }
        if self.ohat.active {
            let t = self.ohat.age;
            let n = self.white();
            dry += n * (-t * 9.0).exp() * 0.16;
            self.ohat.age += dt;
            self.ohat.active = t < 0.5;
        }
        if self.bass.active {
            let t = self.bass.age;
            self.bass_phase = (self.bass_phase + self.bass_freq * dt).fract();
            let saw = self.bass_phase * 2.0 - 1.0;
            let sine = (2.0 * PI * self.bass_phase).sin();
            let env = (-t * 9.0).exp();
            let alpha = (0.03 + (0.15 + cutoff * 0.5) * env).min(0.99);
            self.bass_lp += alpha * (saw - self.bass_lp);
            dry += (self.bass_lp * 0.6 + sine * 0.5 * sub) * env * 0.7;
            self.bass.age += dt;
            self.bass.active = t < 0.4;
        }
        if self.lead.active {
            let t = self.lead.age;
            let spread = detune * 0.014;
            let mut s = 0.0;
            for (i, ph) in self.lead_phase.iter_mut().enumerate() {
                let ratio = 1.0 + (i as f32 - 1.0) * spread;
                *ph = (*ph + self.lead_freq * ratio * dt).fract();
                s += *ph * 2.0 - 1.0;
            }
            let env = (-t * 5.5).exp();
            let alpha = (0.02 + cutoff * 0.6 * env).min(0.99);
            self.lead_lp += alpha * (s / 3.0 - self.lead_lp);
            let v = self.lead_lp * env * 0.45;
            dry += v;
            send += v;
            self.lead.age += dt;
            self.lead.active = t < 0.7;
        }

        // dotted-eighth delay on the lead, feedback 0.45
        let dlen = ((self.step_len() * 3.0) as usize).clamp(1, DELAY_MAX - 1);
        let read = (self.delay_pos + DELAY_MAX - dlen) % DELAY_MAX;
        let echo = self.delay[read];
        self.delay[self.delay_pos] = send + echo * 0.45;
        self.delay_pos = (self.delay_pos + 1) % DELAY_MAX;

        let mix = dry + echo * 0.35;
        let k = 1.0 + drive * 3.0;
        ((mix * k).tanh() / k.tanh()) * 0.8 * volume
    }

    /// Returns true when the pattern changed and should be persisted.
    fn apply(&mut self, cmd: &Value) -> bool {
        match cmd["cmd"].as_str() {
            Some("play") => {
                self.playing = true;
                self.step = 0;
                self.samples_left = 0.0;
                false
            }
            Some("stop") => {
                self.playing = false;
                false
            }
            Some("toggle") => {
                self.apply(&json!({"cmd": if self.playing { "stop" } else { "play" }}))
            }
            Some("bpm") => self.set_f("bpm", cmd["value"].as_f64()),
            Some("swing") => self.set_f("swing", cmd["value"].as_f64()),
            Some("volume") => self.set_f("volume", cmd["value"].as_f64()),
            Some("tone") => {
                let mut changed = false;
                for k in ["cutoff", "detune", "drive", "sub"] {
                    changed |= self.set_f(k, cmd[k].as_f64());
                }
                if let Some(t) = cmd["transpose"].as_u64() {
                    self.pattern.transpose = (t % 12) as u8;
                    changed = true;
                }
                changed
            }
            Some("step") => {
                let t = DRUMS.iter().position(|t| Some(*t) == cmd["track"].as_str());
                let i = cmd["index"].as_u64().map(|i| i as usize).filter(|i| *i < STEPS);
                if let (Some(t), Some(i)) = (t, i) {
                    self.pattern.drums[t][i] = cmd["on"].as_bool().unwrap_or(!self.pattern.drums[t][i]);
                    return true;
                }
                false
            }
            Some("note") => {
                let t = NOTE_TRACKS.iter().position(|t| Some(*t) == cmd["track"].as_str());
                let i = cmd["index"].as_u64().map(|i| i as usize).filter(|i| *i < STEPS);
                let n = cmd["note"].as_u64().filter(|n| *n < 128);
                if let (Some(t), Some(i), Some(n)) = (t, i, n) {
                    self.pattern.notes[t][i] = n as u8;
                    return true;
                }
                false
            }
            Some("clear") => {
                match cmd["track"].as_str() {
                    Some(name) => {
                        if let Some(t) = DRUMS.iter().position(|d| *d == name) {
                            self.pattern.drums[t] = [false; STEPS];
                        } else if let Some(t) = NOTE_TRACKS.iter().position(|d| *d == name) {
                            self.pattern.notes[t] = [0; STEPS];
                        } else {
                            return false;
                        }
                    }
                    None => {
                        self.pattern.drums = [[false; STEPS]; 4];
                        self.pattern.notes = [[0; STEPS]; 2];
                    }
                }
                true
            }
            Some("random") => {
                let name = cmd["track"].as_str().unwrap_or("");
                if let Some(t) = DRUMS.iter().position(|d| *d == name) {
                    let density = [0.35, 0.2, 0.55, 0.15][t];
                    for i in 0..STEPS {
                        let r = (self.white() + 1.0) * 0.5;
                        let downbeat = t == 0 && i % 4 == 0;
                        self.pattern.drums[t][i] = downbeat || r < density;
                    }
                } else if let Some(t) = NOTE_TRACKS.iter().position(|d| *d == name) {
                    let (root, density) = if t == 0 { (33u8, 0.55) } else { (57u8, 0.4) };
                    for i in 0..STEPS {
                        let r = (self.white() + 1.0) * 0.5;
                        self.pattern.notes[t][i] = if r < density {
                            let deg = ((self.white() + 1.0) * 0.5 * SCALE.len() as f32) as usize % SCALE.len();
                            let oct = if self.white() > 0.6 { 12 } else { 0 };
                            root + SCALE[deg] + oct
                        } else {
                            0
                        };
                    }
                } else {
                    return false;
                }
                true
            }
            Some("preset") => {
                let name = cmd["name"].as_str().unwrap_or("y2k");
                match Pattern::preset(name) {
                    Some(p) => {
                        self.pattern = p;
                        true
                    }
                    None => {
                        self.emit(json!({"event": "error", "message": format!("unknown preset {name}; presets: {}", PRESETS.join(", "))}));
                        false
                    }
                }
            }
            Some("load") => {
                if let Some(code) = cmd["code"].as_str() {
                    match Pattern::from_code(code) {
                        Ok(p) => {
                            let volume = self.pattern.volume;
                            self.pattern = p;
                            self.pattern.volume = volume;
                            return true;
                        }
                        Err(e) => {
                            self.emit(json!({"event": "error", "message": e}));
                            return false;
                        }
                    }
                }
                self.pattern.merge(cmd);
                true
            }
            Some("generate") => {
                let f = |k: &str, d: f32| cmd[k].as_f64().map(|x| x as f32).unwrap_or(d).clamp(0.0, 1.0);
                let seed = cmd["seed"].as_u64().unwrap_or(1);
                let volume = self.pattern.volume;
                self.pattern = Pattern::generate(seed, f("energy", 0.5), f("warmth", 0.5), f("brightness", 0.1), f("spice", 0.5));
                self.pattern.volume = volume;
                true
            }
            Some("code") => {
                self.emit(json!({"event": "code", "code": self.pattern.to_code()}));
                false
            }
            Some("save") => {
                let (Some(dir), Some(name)) = (self.library.clone(), cmd["name"].as_str().and_then(safe_name)) else {
                    self.emit(json!({"event": "error", "message": "save needs a name (letters, digits, space, - _)"}));
                    return false;
                };
                self.pattern.preset = name.clone();
                let _ = std::fs::create_dir_all(&dir);
                match std::fs::write(dir.join(format!("{name}.json")), self.pattern.to_json(false).to_string()) {
                    Ok(()) => { self.emit_library(); true }
                    Err(e) => { self.emit(json!({"event": "error", "message": format!("save failed: {e}")})); false }
                }
            }
            Some("open") => {
                let (Some(dir), Some(name)) = (self.library.clone(), cmd["name"].as_str().and_then(safe_name)) else { return false };
                match std::fs::read_to_string(dir.join(format!("{name}.json"))).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
                    Some(v) => {
                        let volume = self.pattern.volume;
                        self.pattern = Pattern::blank(&name, 138.0);
                        self.pattern.merge(&v);
                        self.pattern.preset = name;
                        self.pattern.volume = volume;
                        true
                    }
                    None => { self.emit(json!({"event": "error", "message": format!("no saved loop named {name}")})); false }
                }
            }
            Some("delete") => {
                let (Some(dir), Some(name)) = (self.library.clone(), cmd["name"].as_str().and_then(safe_name)) else { return false };
                let _ = std::fs::remove_file(dir.join(format!("{name}.json")));
                self.emit_library();
                false
            }
            Some("list") => {
                self.emit_library();
                false
            }
            Some("dump") => {
                self.emit(self.pattern.to_json(self.playing));
                false
            }
            Some("export") => {
                let path = cmd["path"].as_str().unwrap_or("omaloop.wav").to_string();
                let bars = cmd["bars"].as_u64().unwrap_or(4).clamp(1, 64) as usize;
                let pattern = self.pattern.clone();
                let events = self.events.clone();
                std::thread::spawn(move || {
                    let msg = match render(&path, bars, Some(pattern)) {
                        Ok(()) => json!({"event": "exported", "path": path, "bars": bars}),
                        Err(e) => json!({"event": "error", "message": format!("export failed: {e}")}),
                    };
                    if let Some(tx) = events {
                        let _ = tx.send(msg);
                    }
                });
                false
            }
            _ => false,
        }
    }

    fn emit_library(&self) {
        let mut names: Vec<String> = self
            .library
            .as_ref()
            .and_then(|d| std::fs::read_dir(d).ok())
            .map(|rd| {
                rd.filter_map(|e| e.ok())
                    .filter_map(|e| e.path().file_stem().map(|s| s.to_string_lossy().to_string()).filter(|_| e.path().extension().map(|x| x == "json").unwrap_or(false)))
                    .collect()
            })
            .unwrap_or_default();
        names.sort_by_key(|n| n.to_lowercase());
        self.emit(json!({"event": "library", "names": names}));
    }

    fn set_f(&mut self, key: &str, v: Option<f64>) -> bool {
        let Some(v) = v else { return false };
        let v = v as f32;
        let p = &mut self.pattern;
        match key {
            "bpm" => p.bpm = v.clamp(40.0, 300.0),
            "swing" => p.swing = v.clamp(0.0, 1.0),
            "volume" => p.volume = v.clamp(0.0, 1.0),
            "cutoff" => p.cutoff = v.clamp(0.0, 1.0),
            "detune" => p.detune = v.clamp(0.0, 1.0),
            "drive" => p.drive = v.clamp(0.0, 1.0),
            "sub" => p.sub = v.clamp(0.0, 1.0),
            _ => return false,
        }
        true
    }
}

fn render(path: &str, bars: usize, pattern: Option<Pattern>) -> Result<(), String> {
    let sr = 48_000.0;
    let mut e = Engine::new(sr, None);
    if let Some(p) = pattern {
        e.pattern = p;
    }
    e.apply(&json!({"cmd": "play"}));
    let total = (e.step_len() * STEPS as f32 * bars as f32) as usize;
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: sr as u32,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    if let Some(dir) = std::path::Path::new(path).parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
    }
    let mut w = hound::WavWriter::create(path, spec).map_err(|e| e.to_string())?;
    for _ in 0..total {
        w.write_sample((e.next_sample() * i16::MAX as f32) as i16).map_err(|e| e.to_string())?;
    }
    w.finalize().map_err(|e| e.to_string())
}

fn arg_after(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn save_state(path: &str, pattern: &Pattern) {
    if let Some(dir) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, pattern.to_json(false).to_string());
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(path) = arg_after(&args, "--render") {
        let bars = arg_after(&args, "--bars").and_then(|b| b.parse().ok()).unwrap_or(2);
        let pattern = arg_after(&args, "--code")
            .and_then(|c| Pattern::from_code(&c).ok())
            .or_else(|| arg_after(&args, "--preset").and_then(|p| Pattern::preset(&p)));
        match render(&path, bars, pattern) {
            Ok(()) => eprintln!("rendered {bars} bars to {path}"),
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        return;
    }

    let host = cpal::default_host();
    let device = host.default_output_device().expect("no output device");
    let config = device.default_output_config().expect("no output config");
    let sr = config.sample_rate().0 as f32;
    let channels = config.channels() as usize;

    let (tx, rx) = channel();
    // ponytail: one mutex shared by the audio callback and stdin; per-field atomics if it ever xruns.
    let engine = Arc::new(Mutex::new(Engine::new(sr, Some(tx))));
    let state_path = arg_after(&args, "--state");
    if let Some(p) = &state_path {
        engine.lock().library = std::path::Path::new(p).parent().map(|d| d.join("patterns"));
        if let Ok(text) = std::fs::read_to_string(p) {
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                engine.lock().pattern.merge(&v);
            }
        }
    }

    let cb_engine = engine.clone();
    let stream = device
        .build_output_stream(
            &config.into(),
            move |data: &mut [f32], _| {
                let mut e = cb_engine.lock();
                for frame in data.chunks_mut(channels) {
                    let s = e.next_sample();
                    frame.fill(s);
                }
            },
            |err| eprintln!("stream error: {err}"),
            None,
        )
        .expect("build stream");
    stream.play().expect("play stream");

    std::thread::spawn(move || {
        let stdout = std::io::stdout();
        for ev in rx {
            let mut o = stdout.lock();
            let _ = writeln!(o, "{ev}");
            let _ = o.flush();
        }
    });

    if args.iter().any(|a| a == "--play") {
        engine.lock().apply(&json!({"cmd": "play"}));
    }
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(cmd) = serde_json::from_str::<Value>(&line) else { continue };
        let changed = engine.lock().apply(&cmd);
        if changed {
            if let Some(p) = &state_path {
                let pattern = engine.lock().pattern.clone();
                save_state(p, &pattern);
            }
        }
    }
}
