//! omaloop engine: a 16-step groovebox that speaks JSON lines on stdin/stdout.
//!
//! Tracks: kick, snare, hat (synthesized drums) and lead (three detuned saws,
//! a nod to FruityLoops' 3xOSC). Everything is generated; no samples.
//!
//! stdin  <- {"cmd":"play"} | {"cmd":"stop"} | {"cmd":"bpm","value":138}
//!           {"cmd":"step","track":"kick","index":0,"on":true}
//!           {"cmd":"note","index":0,"note":57}   (MIDI note, 0 = rest)
//!           {"cmd":"tone","cutoff":0.4,"detune":0.6}
//!           {"cmd":"dump"}
//! stdout -> {"event":"step","index":n} on every step, {"event":"state",...} on dump
//!
//! `--render out.wav --bars N` renders offline instead of opening a device.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use serde_json::{json, Value};
use std::f32::consts::PI;
use std::io::{BufRead, Write};
use std::sync::mpsc::{channel, Sender};
use parking_lot::Mutex;
use std::sync::Arc;

const STEPS: usize = 16;
const TRACKS: [&str; 3] = ["kick", "snare", "hat"];

#[derive(Clone)]
struct Pattern {
    drums: [[bool; STEPS]; 3],
    notes: [u8; STEPS],
    bpm: f32,
    cutoff: f32,
    detune: f32,
}

impl Pattern {
    /// Default: 1999-flavoured techno in A minor.
    fn y2k() -> Self {
        let mut p = Pattern {
            drums: [[false; STEPS]; 3],
            notes: [0; STEPS],
            bpm: 138.0,
            cutoff: 0.45,
            detune: 0.5,
        };
        for i in (0..STEPS).step_by(4) {
            p.drums[0][i] = true;
        }
        p.drums[1][4] = true;
        p.drums[1][12] = true;
        for i in (2..STEPS).step_by(4) {
            p.drums[2][i] = true;
        }
        p.notes = [57, 0, 57, 0, 60, 0, 57, 0, 64, 0, 62, 0, 60, 0, 59, 0];
        p
    }
}

struct Voice {
    age: f32,
    active: bool,
}

struct Engine {
    pattern: Pattern,
    playing: bool,
    sample_rate: f32,
    step: usize,
    samples_into_step: f32,
    kick: Voice,
    snare: Voice,
    hat: Voice,
    lead: Voice,
    lead_freq: f32,
    lead_phase: [f32; 3],
    lead_lp: f32,
    noise: u32,
    events: Sender<Value>,
}

impl Engine {
    fn new(sample_rate: f32, events: Sender<Value>) -> Self {
        let off = || Voice { age: 1e9, active: false };
        Engine {
            pattern: Pattern::y2k(),
            playing: false,
            sample_rate,
            step: 0,
            samples_into_step: 0.0,
            kick: off(),
            snare: off(),
            hat: off(),
            lead: off(),
            lead_freq: 0.0,
            lead_phase: [0.0; 3],
            lead_lp: 0.0,
            noise: 0x1234_5678,
            events,
        }
    }

    fn samples_per_step(&self) -> f32 {
        self.sample_rate * 60.0 / self.pattern.bpm / 4.0
    }

    fn white(&mut self) -> f32 {
        self.noise ^= self.noise << 13;
        self.noise ^= self.noise >> 17;
        self.noise ^= self.noise << 5;
        (self.noise as f32 / u32::MAX as f32) * 2.0 - 1.0
    }

    fn trigger_step(&mut self) {
        let p = &self.pattern;
        if p.drums[0][self.step] {
            self.kick = Voice { age: 0.0, active: true };
        }
        if p.drums[1][self.step] {
            self.snare = Voice { age: 0.0, active: true };
        }
        if p.drums[2][self.step] {
            self.hat = Voice { age: 0.0, active: true };
        }
        let n = p.notes[self.step];
        if n > 0 {
            self.lead = Voice { age: 0.0, active: true };
            self.lead_freq = 440.0 * 2f32.powf((n as f32 - 69.0) / 12.0);
        }
        let _ = self.events.send(json!({"event": "step", "index": self.step}));
    }

    fn next_sample(&mut self) -> f32 {
        if self.playing {
            if self.samples_into_step <= 0.0 {
                self.trigger_step();
                self.samples_into_step = self.samples_per_step();
            }
            self.samples_into_step -= 1.0;
            if self.samples_into_step <= 0.0 {
                self.step = (self.step + 1) % STEPS;
            }
        }
        let dt = 1.0 / self.sample_rate;
        let mut out = 0.0;

        if self.kick.active {
            let t = self.kick.age;
            let f = 50.0 + 100.0 * (-t * 40.0).exp();
            out += (2.0 * PI * f * t).sin() * (-t * 9.0).exp() * 0.9;
            self.kick.age += dt;
            self.kick.active = t < 0.5;
        }
        if self.snare.active {
            let t = self.snare.age;
            let n = self.white();
            out += (n * 0.5 + (2.0 * PI * 180.0 * t).sin() * 0.3) * (-t * 18.0).exp() * 0.6;
            self.snare.age += dt;
            self.snare.active = t < 0.3;
        }
        if self.hat.active {
            let t = self.hat.age;
            let n = self.white();
            out += n * (-t * 80.0).exp() * 0.25;
            self.hat.age += dt;
            self.hat.active = t < 0.12;
        }
        if self.lead.active {
            let t = self.lead.age;
            let spread = self.pattern.detune * 0.012;
            let mut s = 0.0;
            for (i, ph) in self.lead_phase.iter_mut().enumerate() {
                let ratio = 1.0 + (i as f32 - 1.0) * spread;
                *ph = (*ph + self.lead_freq * ratio * dt).fract();
                s += *ph * 2.0 - 1.0;
            }
            // one-pole lowpass; cutoff sweeps down with the envelope like a 303-ish pluck
            let env = (-t * 6.0).exp();
            let alpha = (0.02 + self.pattern.cutoff * 0.6 * env).min(0.99);
            self.lead_lp += alpha * (s / 3.0 - self.lead_lp);
            out += self.lead_lp * env * 0.5;
            self.lead.age += dt;
            self.lead.active = t < 0.6;
        }
        (out * 0.7).clamp(-1.0, 1.0)
    }

    fn apply(&mut self, cmd: &Value) {
        match cmd["cmd"].as_str() {
            Some("play") => {
                self.playing = true;
                self.step = 0;
                self.samples_into_step = 0.0;
            }
            Some("stop") => self.playing = false,
            Some("bpm") => {
                if let Some(v) = cmd["value"].as_f64() {
                    self.pattern.bpm = (v as f32).clamp(40.0, 300.0);
                }
            }
            Some("step") => {
                let track = TRACKS.iter().position(|t| Some(*t) == cmd["track"].as_str());
                let idx = cmd["index"].as_u64().map(|i| i as usize);
                if let (Some(t), Some(i)) = (track, idx) {
                    if i < STEPS {
                        self.pattern.drums[t][i] = cmd["on"].as_bool().unwrap_or(true);
                    }
                }
            }
            Some("note") => {
                if let (Some(i), Some(n)) = (cmd["index"].as_u64(), cmd["note"].as_u64()) {
                    if (i as usize) < STEPS && n < 128 {
                        self.pattern.notes[i as usize] = n as u8;
                    }
                }
            }
            Some("tone") => {
                if let Some(c) = cmd["cutoff"].as_f64() {
                    self.pattern.cutoff = (c as f32).clamp(0.0, 1.0);
                }
                if let Some(d) = cmd["detune"].as_f64() {
                    self.pattern.detune = (d as f32).clamp(0.0, 1.0);
                }
            }
            Some("dump") => {
                let p = &self.pattern;
                let _ = self.events.send(json!({
                    "event": "state",
                    "playing": self.playing,
                    "bpm": p.bpm,
                    "cutoff": p.cutoff,
                    "detune": p.detune,
                    "kick": p.drums[0], "snare": p.drums[1], "hat": p.drums[2],
                    "notes": p.notes,
                }));
            }
            _ => {}
        }
    }
}

fn render(path: &str, bars: usize) {
    let sr = 48_000.0;
    let (tx, _rx) = channel();
    let mut e = Engine::new(sr, tx);
    e.apply(&json!({"cmd": "play"}));
    let total = (e.samples_per_step() * STEPS as f32 * bars as f32) as usize;
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: sr as u32,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).expect("create wav");
    for _ in 0..total {
        w.write_sample((e.next_sample() * i16::MAX as f32) as i16).unwrap();
    }
    w.finalize().unwrap();
    eprintln!("rendered {bars} bars ({total} samples) to {path}");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--render") {
        let path = args.get(i + 1).expect("--render <file.wav>");
        let bars = args
            .iter()
            .position(|a| a == "--bars")
            .and_then(|j| args.get(j + 1))
            .and_then(|b| b.parse().ok())
            .unwrap_or(2);
        return render(path, bars);
    }

    let host = cpal::default_host();
    let device = host.default_output_device().expect("no output device");
    let config = device.default_output_config().expect("no output config");
    let sr = config.sample_rate().0 as f32;
    let channels = config.channels() as usize;

    let (tx, rx) = channel();
    // ponytail: one mutex shared by the audio callback and stdin; per-field atomics if it ever xruns.
    let engine = Arc::new(Mutex::new(Engine::new(sr, tx)));
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
        if let Ok(cmd) = serde_json::from_str::<Value>(&line) {
            engine.lock().apply(&cmd);
        }
    }
}
