//! Deterministic, software-only video export support.
//!
//! The regular engine keeps its realtime/WAV behaviour in `main.rs`.  This
//! module adds a frozen offline job path: one bounded audio loop is rendered
//! after a short warm-up, one RGB frame is generated at a time, and ffmpeg is
//! fed through pipes.  No rendered frame sequence is kept on disk or in RAM.

use super::*;
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, SystemTime};

const SAMPLE_RATE: u32 = 48_000;
const FPS: u32 = 30;
const WARMUP_CYCLES: usize = 4;
const CROSSFADE_SAMPLES: usize = 128;
const MAX_HANDLE_CHARS: usize = 64;
const MAX_JOB_ID_CHARS: usize = 80;

#[derive(Clone, Copy, Debug)]
struct Rgb {
    r: u8,
    g: u8,
    b: u8,
}

impl Rgb {
    fn parse(value: Option<&Value>, fallback: Rgb) -> Rgb {
        let Some(value) = value.and_then(Value::as_str) else {
            return fallback;
        };
        let value = value.trim().trim_start_matches('#');
        let (value, alpha) = if value.len() == 8 {
            (&value[..6], &value[6..])
        } else {
            (value, "ff")
        };
        if value.len() != 6 || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
            return fallback;
        }
        let parse = |s: &str| u8::from_str_radix(s, 16).ok();
        let (Some(r), Some(g), Some(b), Some(a)) = (
            parse(&value[0..2]),
            parse(&value[2..4]),
            parse(&value[4..6]),
            parse(alpha),
        ) else {
            return fallback;
        };
        let scale = a as u16;
        Rgb {
            r: ((r as u16 * scale) / 255) as u8,
            g: ((g as u16 * scale) / 255) as u8,
            b: ((b as u16 * scale) / 255) as u8,
        }
    }

    // Use readable theme text when the muted color is too close to the background.
    fn contrast_with(self, other: Rgb) -> f32 {
        let luminance = |color: Rgb| {
            let channel = |v: u8| {
                let v = v as f32 / 255.0;
                if v <= 0.04045 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
            };
            0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
        };
        let a = luminance(self);
        let b = luminance(other);
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    fn mix(self, other: Rgb, amount: f32) -> Rgb {
        let amount = amount.clamp(0.0, 1.0);
        let f = |a: u8, b: u8| {
            (a as f32 + (b as f32 - a as f32) * amount)
                .round()
                .clamp(0.0, 255.0) as u8
        };
        Rgb {
            r: f(self.r, other.r),
            g: f(self.g, other.g),
            b: f(self.b, other.b),
        }
    }
}

#[derive(Clone, Debug)]
struct Palette {
    background: Rgb,
    foreground: Rgb,
    accent: Rgb,
    muted: Rgb,
}

impl Palette {
    fn from_value(value: Option<&Value>) -> Self {
        let default_bg = Rgb {
            r: 18,
            g: 20,
            b: 26,
        };
        let default_fg = Rgb {
            r: 230,
            g: 233,
            b: 240,
        };
        let default_accent = Rgb {
            r: 100,
            g: 180,
            b: 255,
        };
        let default_muted = Rgb {
            r: 125,
            g: 135,
            b: 150,
        };
        let value = value.and_then(Value::as_object);
        Self {
            background: Rgb::parse(value.and_then(|v| v.get("background")), default_bg),
            foreground: Rgb::parse(value.and_then(|v| v.get("foreground")), default_fg),
            accent: Rgb::parse(value.and_then(|v| v.get("accent")), default_accent),
            muted: Rgb::parse(value.and_then(|v| v.get("muted")), default_muted),
        }
    }
}

#[derive(Clone, Debug)]
struct VideoJob {
    id: String,
    pattern: Pattern,
    palette: Palette,
    font_family: String,
    aspect: String,
    quality: String,
    repetitions: usize,
    handle: String,
}

impl VideoJob {
    fn parse(value: &Value) -> Result<Self, String> {
        let object = value.as_object().ok_or("video job must be an object")?;
        let id = bounded_text(
            object.get("jobId").and_then(Value::as_str).unwrap_or(""),
            MAX_JOB_ID_CHARS,
            "job id",
        )?;
        if id.is_empty()
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err("job id must contain only letters, digits, '-' or '_'".into());
        }
        let pattern_value = object
            .get("pattern")
            .ok_or("video job is missing its frozen pattern")?;
        let pattern_object = pattern_value
            .as_object()
            .ok_or("frozen pattern must be an object")?;
        validate_pattern_snapshot(pattern_object)?;
        let bpm = pattern_object
            .get("bpm")
            .and_then(Value::as_f64)
            .ok_or("frozen pattern is missing BPM")? as f32;
        let mut pattern = Pattern::blank(
            pattern_object
                .get("preset")
                .and_then(Value::as_str)
                .unwrap_or("export"),
            bpm,
        );
        pattern.merge(pattern_value);
        let aspect = one_of(
            object
                .get("aspect")
                .and_then(Value::as_str)
                .unwrap_or("portrait"),
            &["portrait", "square", "landscape"],
            "aspect",
        )?;
        let quality = one_of(
            object
                .get("quality")
                .and_then(Value::as_str)
                .unwrap_or("standard"),
            &["standard", "high"],
            "quality",
        )?;
        let repetitions_value = object
            .get("repetitions")
            .and_then(Value::as_u64)
            .ok_or("repetitions must be an integer from 1 to 64")?;
        if !(1..=64).contains(&repetitions_value) {
            return Err("repetitions must be an integer from 1 to 64".into());
        }
        let repetitions = repetitions_value as usize;
        let handle = bounded_text(
            object.get("handle").and_then(Value::as_str).unwrap_or(""),
            MAX_HANDLE_CHARS,
            "social handle",
        )?;
        Ok(Self {
            id,
            pattern,
            palette: Palette::from_value(object.get("palette")),
            font_family: bounded_text(
                object
                    .get("fontFamily")
                    .and_then(Value::as_str)
                    .unwrap_or("monospace"),
                120,
                "font family",
            )?,
            aspect,
            quality,
            repetitions,
            handle,
        })
    }

    fn dimensions(&self) -> (usize, usize) {
        let high = self.quality == "high";
        match (self.aspect.as_str(), high) {
            ("portrait", false) => (720, 1280),
            ("portrait", true) => (1080, 1920),
            ("square", false) => (720, 720),
            ("square", true) => (1080, 1080),
            ("landscape", false) => (1280, 720),
            ("landscape", true) => (1920, 1080),
            _ => (720, 1280),
        }
    }
}

fn validate_pattern_snapshot(pattern: &serde_json::Map<String, Value>) -> Result<(), String> {
    let range = |key: &str, lo: f64, hi: f64| {
        let value = pattern
            .get(key)
            .and_then(Value::as_f64)
            .ok_or_else(|| format!("frozen pattern is missing {key}"))?;
        if !value.is_finite() || value < lo || value > hi {
            return Err(format!(
                "frozen pattern {key} must be between {lo} and {hi}"
            ));
        }
        Ok(())
    };
    range("bpm", 40.0, 300.0)?;
    for key in ["swing", "volume", "cutoff", "detune", "drive", "sub"] {
        range(key, 0.0, 1.0)?;
    }
    let transpose = pattern
        .get("transpose")
        .and_then(Value::as_u64)
        .ok_or("frozen pattern is missing transpose")?;
    if transpose > 11 {
        return Err("frozen pattern transpose must be 0..11".into());
    }
    for key in ["kick", "snare", "hat", "ohat"] {
        let array = pattern
            .get(key)
            .and_then(Value::as_array)
            .ok_or_else(|| format!("frozen pattern is missing {key}"))?;
        if array.len() != STEPS || array.iter().any(|value| value.as_bool().is_none()) {
            return Err(format!(
                "frozen pattern {key} must contain exactly {STEPS} booleans"
            ));
        }
    }
    for key in ["bass", "lead"] {
        let array = pattern
            .get(key)
            .and_then(Value::as_array)
            .ok_or_else(|| format!("frozen pattern is missing {key}"))?;
        if array.len() != STEPS
            || array
                .iter()
                .any(|value| value.as_u64().map(|n| n > 127).unwrap_or(true))
        {
            return Err(format!(
                "frozen pattern {key} must contain exactly {STEPS} MIDI notes"
            ));
        }
    }
    Ok(())
}

fn bounded_text(value: &str, max: usize, label: &str) -> Result<String, String> {
    if value.chars().any(|c| c.is_control()) {
        return Err(format!("{label} contains a control character"));
    }
    let text: String = value.chars().take(max).collect();
    if value.chars().count() > max {
        return Err(format!("{label} is too long (maximum {max} characters)"));
    }
    Ok(text)
}

fn one_of(value: &str, allowed: &[&str], label: &str) -> Result<String, String> {
    if allowed.iter().any(|x| *x == value) {
        Ok(value.to_string())
    } else {
        Err(format!("unsupported {label}: {value}"))
    }
}

/// Exact integer sample boundaries for the 16-step musical cycle.  Swing
/// changes alternating steps, but each pair still sums to two unswung steps.
#[derive(Clone, Debug)]
struct Timeline {
    starts: Vec<usize>,
    cycle_samples: usize,
}

impl Timeline {
    fn new(pattern: &Pattern, sample_rate: u32) -> Result<Self, String> {
        if !pattern.bpm.is_finite() || !(40.0..=300.0).contains(&pattern.bpm) {
            return Err("BPM must be between 40 and 300".into());
        }
        if !pattern.swing.is_finite() || !(0.0..=1.0).contains(&pattern.swing) {
            return Err("swing must be between 0 and 1".into());
        }
        let base = sample_rate as f64 * 60.0 / pattern.bpm as f64 / 4.0;
        let mut starts = Vec::with_capacity(STEPS + 1);
        starts.push(0);
        let mut ideal = 0.0;
        for step in 0..STEPS {
            let factor = if step % 2 == 0 {
                1.0 + pattern.swing as f64 * 0.5
            } else {
                1.0 - pattern.swing as f64 * 0.5
            };
            ideal += base * factor;
            let next = ideal.round() as usize;
            starts.push(next.max(*starts.last().unwrap()));
        }
        let cycle_samples = *starts.last().unwrap();
        if cycle_samples == 0 {
            return Err("musical cycle has no samples".into());
        }
        Ok(Self {
            starts,
            cycle_samples,
        })
    }

    fn step_at(&self, sample: usize) -> usize {
        let sample = sample % self.cycle_samples;
        match self.starts.binary_search(&sample) {
            Ok(i) => i.min(STEPS - 1),
            Err(i) => i.saturating_sub(1).min(STEPS - 1),
        }
    }

    fn seconds(&self) -> f64 {
        self.cycle_samples as f64 / SAMPLE_RATE as f64
    }
}

#[derive(Debug)]
enum ExportFailure {
    Cancelled,
    Message(String),
}

fn cancelled(flag: &AtomicBool) -> bool {
    flag.load(Ordering::Relaxed)
}

fn render_one_sample(
    engine: &mut Engine,
    timeline: &Timeline,
    sample: usize,
    previous_step: &mut Option<usize>,
) -> f32 {
    let step = timeline.step_at(sample);
    if *previous_step != Some(step) {
        engine.step = step;
        engine.trigger_step();
        *previous_step = Some(step);
    }
    // `next_sample` contains the synthesis and effects but its realtime clock
    // is disabled here.  The Timeline above is the only offline clock.
    engine.playing = false;
    engine.next_sample()
}

fn render_loop(
    pattern: &Pattern,
    timeline: &Timeline,
    flag: &AtomicBool,
    emit: &dyn Fn(Value),
) -> Result<Vec<f32>, ExportFailure> {
    let mut engine = Engine::new(SAMPLE_RATE as f32, None);
    engine.pattern = pattern.clone();
    let mut previous_step = None;
    emit(json!({
        "event": "video_export_progress",
        "phase": "audio-warmup",
        "progress": 0.0
    }));
    for warmup in 0..WARMUP_CYCLES {
        for sample in 0..timeline.cycle_samples {
            if cancelled(flag) {
                return Err(ExportFailure::Cancelled);
            }
            let _ = render_one_sample(&mut engine, timeline, sample, &mut previous_step);
        }
        emit(
            json!({"event":"video_export_progress", "phase":"audio-warmup", "progress": (warmup + 1) as f32 / WARMUP_CYCLES as f32 * 0.12}),
        );
    }
    let mut raw = Vec::with_capacity(timeline.cycle_samples);
    for sample in 0..timeline.cycle_samples {
        if cancelled(flag) {
            return Err(ExportFailure::Cancelled);
        }
        raw.push(render_one_sample(
            &mut engine,
            timeline,
            sample,
            &mut previous_step,
        ));
    }
    // A short cyclic overlap is applied at the repeat boundary.  The output
    // starts just after the overlap, so the end-to-start samples are adjacent
    // points from the same deterministic waveform rather than a hard cut.
    let overlap = CROSSFADE_SAMPLES.min(raw.len() / 8).max(1);
    let mut looped = Vec::with_capacity(raw.len());
    for i in 0..raw.len() {
        let phase = (i + overlap) % raw.len();
        // Keep the exported start at a normal adjacent pair (overlap,
        // overlap+1).  Only the tail immediately before the cycle wrap is
        // blended toward the captured head; the following head samples then
        // remain adjacent to that same pair on the next repeat.
        let value = if phase >= raw.len() - overlap {
            let offset = phase - (raw.len() - overlap);
            let w = (offset + 1) as f32 / overlap as f32;
            raw[phase] * (1.0 - w) + raw[offset] * w
        } else {
            raw[phase]
        };
        looped.push(value);
    }
    Ok(looped)
}

fn write_wav(
    path: &Path,
    looped: &[f32],
    repetitions: usize,
    flag: &AtomicBool,
    emit: &dyn Fn(Value),
) -> Result<(), ExportFailure> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec)
        .map_err(|e| ExportFailure::Message(format!("cannot create temporary WAV: {e}")))?;
    let total = looped.len().saturating_mul(repetitions).max(1);
    let progress_stride = (total / 100).max(1);
    let mut written = 0usize;
    for _ in 0..repetitions {
        for sample in looped {
            if cancelled(flag) {
                return Err(ExportFailure::Cancelled);
            }
            let value = (sample * i16::MAX as f32)
                .round()
                .clamp(i16::MIN as f32, i16::MAX as f32) as i16;
            writer.write_sample(value).map_err(|e| {
                ExportFailure::Message(format!("writing temporary WAV failed: {e}"))
            })?;
            written += 1;
            if written % progress_stride == 0 {
                emit(
                    json!({"event":"video_export_progress", "phase":"audio", "progress": 0.12 + written as f32 / total as f32 * 0.12}),
                );
            }
        }
    }
    writer
        .finalize()
        .map_err(|e| ExportFailure::Message(format!("finalizing temporary WAV failed: {e}")))?;
    Ok(())
}

fn fill(buffer: &mut [u8], color: Rgb) {
    for px in buffer.chunks_exact_mut(3) {
        px.copy_from_slice(&[color.r, color.g, color.b]);
    }
}

fn rect(
    buffer: &mut [u8],
    width: usize,
    height: usize,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: Rgb,
) {
    let x0 = x.max(0) as usize;
    let y0 = y.max(0) as usize;
    let x1 = (x + w).min(width as i32).max(0) as usize;
    let y1 = (y + h).min(height as i32).max(0) as usize;
    for yy in y0..y1 {
        let row = yy * width * 3;
        for xx in x0..x1 {
            let p = row + xx * 3;
            buffer[p..p + 3].copy_from_slice(&[color.r, color.g, color.b]);
        }
    }
}

fn glyph(ch: char) -> [&'static str; 7] {
    if ch.is_ascii_lowercase() {
        return match ch {
            'a' => [
                "00000", "00000", "01110", "00001", "01111", "10001", "01111",
            ],
            'b' => [
                "10000", "10000", "10110", "11001", "10001", "10001", "11110",
            ],
            'c' => [
                "00000", "00000", "01111", "10000", "10000", "10000", "01111",
            ],
            'd' => [
                "00001", "00001", "01101", "10011", "10001", "10001", "01111",
            ],
            'e' => [
                "00000", "00000", "01110", "10001", "11111", "10000", "01111",
            ],
            'f' => [
                "00110", "01001", "01000", "11100", "01000", "01000", "01000",
            ],
            'g' => [
                "00000", "01111", "10001", "10001", "01111", "00001", "01110",
            ],
            'h' => [
                "10000", "10000", "10110", "11001", "10001", "10001", "10001",
            ],
            'i' => [
                "00100", "00000", "01100", "00100", "00100", "00100", "01110",
            ],
            'j' => [
                "00010", "00000", "00110", "00010", "00010", "10010", "01100",
            ],
            'k' => [
                "10000", "10000", "10010", "10100", "11000", "10100", "10010",
            ],
            'l' => [
                "01100", "00100", "00100", "00100", "00100", "00100", "01110",
            ],
            'm' => [
                "00000", "00000", "11010", "10101", "10101", "10101", "10101",
            ],
            'n' => [
                "00000", "00000", "10110", "11001", "10001", "10001", "10001",
            ],
            'o' => [
                "00000", "00000", "01110", "10001", "10001", "10001", "01110",
            ],
            'p' => [
                "00000", "11110", "10001", "10001", "11110", "10000", "10000",
            ],
            'q' => [
                "00000", "01101", "10011", "10001", "01111", "00001", "00001",
            ],
            'r' => [
                "00000", "00000", "10110", "11001", "10000", "10000", "10000",
            ],
            's' => [
                "00000", "00000", "01111", "10000", "01110", "00001", "11110",
            ],
            't' => [
                "01000", "01000", "11100", "01000", "01000", "01001", "00110",
            ],
            'u' => [
                "00000", "00000", "10001", "10001", "10001", "10011", "01101",
            ],
            'v' => [
                "00000", "00000", "10001", "10001", "10001", "01010", "00100",
            ],
            'w' => [
                "00000", "00000", "10001", "10001", "10101", "10101", "01010",
            ],
            'x' => [
                "00000", "00000", "10001", "01010", "00100", "01010", "10001",
            ],
            'y' => [
                "00000", "10001", "10001", "10001", "01111", "00001", "01110",
            ],
            'z' => [
                "00000", "00000", "11111", "00010", "00100", "01000", "11111",
            ],
            _ => unreachable!(),
        };
    }
    match ch {
        'A' => [
            "01110", "10001", "10001", "11111", "10001", "10001", "10001",
        ],
        'B' => [
            "11110", "10001", "10001", "11110", "10001", "10001", "11110",
        ],
        'C' => [
            "01111", "10000", "10000", "10000", "10000", "10000", "01111",
        ],
        'D' => [
            "11110", "10001", "10001", "10001", "10001", "10001", "11110",
        ],
        'E' => [
            "11111", "10000", "10000", "11110", "10000", "10000", "11111",
        ],
        'F' => [
            "11111", "10000", "10000", "11110", "10000", "10000", "10000",
        ],
        'G' => [
            "01111", "10000", "10000", "10111", "10001", "10001", "01111",
        ],
        'H' => [
            "10001", "10001", "10001", "11111", "10001", "10001", "10001",
        ],
        'I' => [
            "11111", "00100", "00100", "00100", "00100", "00100", "11111",
        ],
        'J' => [
            "00111", "00010", "00010", "00010", "00010", "10010", "01100",
        ],
        'K' => [
            "10001", "10010", "10100", "11000", "10100", "10010", "10001",
        ],
        'L' => [
            "10000", "10000", "10000", "10000", "10000", "10000", "11111",
        ],
        'M' => [
            "10001", "11011", "10101", "10101", "10001", "10001", "10001",
        ],
        'N' => [
            "10001", "11001", "10101", "10011", "10001", "10001", "10001",
        ],
        'O' => [
            "01110", "10001", "10001", "10001", "10001", "10001", "01110",
        ],
        'P' => [
            "11110", "10001", "10001", "11110", "10000", "10000", "10000",
        ],
        'Q' => [
            "01110", "10001", "10001", "10001", "10101", "10010", "01101",
        ],
        'R' => [
            "11110", "10001", "10001", "11110", "10100", "10010", "10001",
        ],
        'S' => [
            "01111", "10000", "10000", "01110", "00001", "00001", "11110",
        ],
        'T' => [
            "11111", "00100", "00100", "00100", "00100", "00100", "00100",
        ],
        'U' => [
            "10001", "10001", "10001", "10001", "10001", "10001", "01110",
        ],
        'V' => [
            "10001", "10001", "10001", "10001", "10001", "01010", "00100",
        ],
        'W' => [
            "10001", "10001", "10001", "10101", "10101", "11011", "10001",
        ],
        'X' => [
            "10001", "10001", "01010", "00100", "01010", "10001", "10001",
        ],
        'Y' => [
            "10001", "10001", "01010", "00100", "00100", "00100", "00100",
        ],
        'Z' => [
            "11111", "00001", "00010", "00100", "01000", "10000", "11111",
        ],
        '0' => [
            "01110", "10001", "10011", "10101", "11001", "10001", "01110",
        ],
        '1' => [
            "00100", "01100", "00100", "00100", "00100", "00100", "01110",
        ],
        '2' => [
            "01110", "10001", "00001", "00010", "00100", "01000", "11111",
        ],
        '3' => [
            "11110", "00001", "00001", "01110", "00001", "00001", "11110",
        ],
        '4' => [
            "00010", "00110", "01010", "10010", "11111", "00010", "00010",
        ],
        '5' => [
            "11111", "10000", "10000", "11110", "00001", "00001", "11110",
        ],
        '6' => [
            "01110", "10000", "10000", "11110", "10001", "10001", "01110",
        ],
        '7' => [
            "11111", "00001", "00010", "00100", "01000", "01000", "01000",
        ],
        '8' => [
            "01110", "10001", "10001", "01110", "10001", "10001", "01110",
        ],
        '9' => [
            "01110", "10001", "10001", "01111", "00001", "00001", "01110",
        ],
        '-' => [
            "00000", "00000", "00000", "11111", "00000", "00000", "00000",
        ],
        '_' => [
            "00000", "00000", "00000", "00000", "00000", "00000", "11111",
        ],
        '.' => [
            "00000", "00000", "00000", "00000", "00000", "00110", "00110",
        ],
        ':' => [
            "00000", "00110", "00110", "00000", "00110", "00110", "00000",
        ],
        '@' => [
            "01110", "10001", "10111", "10101", "10111", "10000", "01110",
        ],
        '/' => [
            "00001", "00010", "00100", "01000", "10000", "00000", "00000",
        ],
        '#' => [
            "01010", "11111", "01010", "01010", "11111", "01010", "00000",
        ],
        '?' => [
            "01110", "10001", "00001", "00010", "00100", "00000", "00100",
        ],
        '=' => [
            "00000", "00000", "11111", "00000", "11111", "00000", "00000",
        ],
        '+' => [
            "00000", "00100", "00100", "11111", "00100", "00100", "00000",
        ],
        _ => [
            "01110", "10001", "00001", "00010", "00100", "00000", "00100",
        ],
    }
}

// /////////////////////////////////////////////////////////////////////////////
// Video text
//
// Resolve Omarchy's configured font once per export and cache each rasterized
// character. If font discovery is unavailable, the built-in bitmap alphabet
// still lets exports finish without installing a system package.
// /////////////////////////////////////////////////////////////////////////////

static VIDEO_FONT: OnceLock<Option<fontdue::Font>> = OnceLock::new();
static VIDEO_GLYPHS: OnceLock<Mutex<HashMap<(char, i32), (fontdue::Metrics, Vec<u8>)>>> =
    OnceLock::new();

fn init_video_font(family: &str) {
    VIDEO_FONT.get_or_init(|| {
        let output = Command::new("fc-match")
            .args(["-f", "%{file}", family])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let path = std::str::from_utf8(&output.stdout).ok()?.trim();
        let bytes = fs::read(path).ok()?;
        fontdue::Font::from_bytes(bytes, fontdue::FontSettings::default()).ok()
    });
}

fn text_width(text: &str, scale: i32) -> i32 {
    if let Some(font) = VIDEO_FONT.get().and_then(|font| font.as_ref()) {
        text.chars()
            .map(|ch| font.metrics(ch, (scale.max(1) * 8) as f32).advance_width)
            .sum::<f32>()
            .ceil() as i32
    } else {
        text.chars().count() as i32 * 6 * scale.max(1)
    }
}

fn fit_handle(handle: &str, scale: i32, max_width: i32) -> String {
    if text_width(handle, scale) <= max_width {
        return handle.to_string();
    }
    let mut shown = String::new();
    for ch in handle.chars() {
        let candidate = format!("{shown}{ch}...");
        if text_width(&candidate, scale) > max_width {
            break;
        }
        shown.push(ch);
    }
    format!("{shown}...")
}

fn draw_font_text(
    buffer: &mut [u8],
    width: usize,
    height: usize,
    x: i32,
    y: i32,
    text: &str,
    pixel_size: i32,
    color: Rgb,
    max_width: Option<i32>,
) -> bool {
    let Some(font) = VIDEO_FONT.get().and_then(|font| font.as_ref()) else {
        return false;
    };

    let baseline = y + (pixel_size as f32 * 0.86).round() as i32;
    let mut cursor = x as f32;
    let cache = VIDEO_GLYPHS.get_or_init(|| Mutex::new(HashMap::new()));
    let Ok(mut cache) = cache.lock() else {
        return false;
    };
    for ch in text.chars() {
        let (metrics, pixels) = cache
            .entry((ch, pixel_size))
            .or_insert_with(|| font.rasterize(ch, pixel_size as f32));
        if max_width
            .map(|limit| cursor - x as f32 + metrics.advance_width > limit as f32)
            .unwrap_or(false)
        {
            break;
        }
        let left = cursor.round() as i32 + metrics.xmin;
        let top = baseline - metrics.height as i32 - metrics.ymin;
        for row in 0..metrics.height {
            for col in 0..metrics.width {
                let px = left + col as i32;
                let py = top + row as i32;
                if px < 0 || py < 0 || px >= width as i32 || py >= height as i32 {
                    continue;
                }
                let alpha = pixels[row * metrics.width + col] as u16;
                let i = (py as usize * width + px as usize) * 3;
                for (offset, channel) in [color.r, color.g, color.b].iter().enumerate() {
                    buffer[i + offset] = ((buffer[i + offset] as u16 * (255 - alpha)
                        + *channel as u16 * alpha)
                        / 255) as u8;
                }
            }
        }
        cursor += metrics.advance_width;
    }
    true
}

fn draw_text(
    buffer: &mut [u8],
    width: usize,
    height: usize,
    x: i32,
    y: i32,
    text: &str,
    pixel_size: i32,
    color: Rgb,
    max_width: Option<i32>,
) {
    if draw_font_text(buffer, width, height, x, y, text, pixel_size, color, max_width) {
        return;
    }
    let scale = ((pixel_size + 4) / 8).max(1);
    let advance = 6 * scale;
    let max_chars = max_width.map(|w| (w / advance).max(1) as usize);
    let mut cursor = x;
    for (index, ch) in text.chars().enumerate() {
        if max_chars.map(|n| index >= n).unwrap_or(false) {
            break;
        }
        if ch == ' ' {
            cursor += advance;
            continue;
        }
        let rows = glyph(ch);
        for (row, pattern) in rows.iter().enumerate() {
            for (column, bit) in pattern.bytes().enumerate() {
                if bit == b'1' {
                    rect(
                        buffer,
                        width,
                        height,
                        cursor + column as i32 * scale,
                        y + row as i32 * scale,
                        scale,
                        scale,
                        color.clone(),
                    );
                }
            }
        }
        cursor += advance;
    }
}

// /////////////////////////////////////////////////////////////////////////////
// Video frame layout
//
// Draw the frozen theme and pattern as a compact Omaloop grid. The header,
// grid, and credits share one layout for previews and exported frames, so
// changing the output shape does not change the information being shown.
// /////////////////////////////////////////////////////////////////////////////

const OMARCHY_URL: &str = "omarchy.org";
const PLUGIN_URL_FIRST: &str = "plugins.omarchy.org/";
const PLUGIN_URL_LAST: &str = "plugin.html?id=io.github.";
const PLUGIN_URL_END: &str = "joshuaswarren.omaloop";

fn rounded_rect(
    buffer: &mut [u8],
    width: usize,
    height: usize,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: Rgb,
) {
    let radius = (w.min(h) / 7).clamp(1, 8);
    for row in 0..h {
        let edge = row.min(h - 1 - row);
        let inset = if edge < radius {
            (radius - edge) / 2
        } else {
            0
        };
        rect(
            buffer,
            width,
            height,
            x + inset,
            y + row,
            w - inset * 2,
            1,
            color,
        );
    }
}

fn render_frame(job: &VideoJob, timeline: &Timeline, frame: usize, buffer: &mut Vec<u8>) {
    let (width, height) = job.dimensions();
    if job.aspect == "portrait" {
        render_portrait_frame(job, timeline, frame, buffer, width, height);
        return;
    }
    if job.aspect == "square" {
        render_square_frame(job, timeline, frame, buffer, width, height);
        return;
    }
    render_landscape_frame(job, timeline, frame, buffer, width, height);
}

// /////////////////////////////////////////////////////////////////////////////
// Square video frame
//
// Put the complete sixteen-step grid at the center of the square, with the
// social handle and credits around it. Small markers identify the first step of each beat.
// /////////////////////////////////////////////////////////////////////////////

fn render_square_frame(
    job: &VideoJob, timeline: &Timeline, frame: usize, buffer: &mut Vec<u8>,
    width: usize, height: usize,
) {
    init_video_font(&job.font_family);
    buffer.resize(width * height * 3, 0);
    fill(buffer, job.palette.background);
    let w = width as i32;
    let h = height as i32;
    let margin = w * 5 / 100;
    let logo_scale = (w / 135).max(1);
    let label_scale = (w / 300).max(1);
    let small_scale = (w / 450).max(1);
    let text_color = job.palette.foreground;
    draw_text(buffer, width, height, margin, h * 8 / 100, "omaloop",
        logo_scale * 8, job.palette.accent, None);
    draw_text(buffer, width, height, margin, h * 8 / 100 + logo_scale * 11,
        "by @joshuaswarren", label_scale * 8, text_color, None);
    let handle = job.handle.trim().trim_start_matches('@').trim_start();
    if !handle.is_empty() {
        let max_width = w - margin * 2 - text_width("omaloop", logo_scale) - label_scale * 4;
        let shown = fit_handle(&format!("@{handle}"), label_scale, max_width);
        let color = if job.palette.accent.contrast_with(job.palette.background) >= 7.0 {
            job.palette.accent
        } else { text_color };
        draw_text(buffer, width, height, w - margin - text_width(&shown, label_scale),
            h * 8 / 100, &shown, label_scale * 8, color, Some(max_width));
    }

    let labels = ["KICK", "SNARE", "HAT", "OHAT", "BASS", "LEAD"];
    let label_width = labels.iter().map(|label| text_width(label, label_scale)).max().unwrap_or(0) + label_scale * 2;
    let gap = (w / 200).max(3);
    let pad = (w - margin * 2 - label_width - gap * 16) / 16;
    let grid_width = label_width + gap * 16 + pad * 16;
    let grid_x = (w - grid_width) / 2;
    let grid_height = 6 * pad + 5 * gap;
    let grid_y = (h - grid_height) / 2;
    let sample = ((frame as u64 * SAMPLE_RATE as u64) / FPS as u64) as usize % timeline.cycle_samples;
    let step = timeline.step_at(sample);
    for beat in 0..4 {
        let column = beat * 4;
        let x = grid_x + label_width + gap + column * (pad + gap);
        let marker = format!("{:02}", column + 1);
        draw_text(buffer, width, height, x, grid_y - small_scale * 13,
            &marker, small_scale * 8, text_color, None);
    }
    for (row, label) in labels.iter().enumerate() {
        let y = grid_y + row as i32 * (pad + gap);
        draw_text(buffer, width, height, grid_x, y + (pad - label_scale * 8) / 2,
            label, label_scale * 8, text_color, Some(label_width));
        for column in 0..16 {
            let active = if row < 4 { job.pattern.drums[row][column] } else { job.pattern.notes[row - 4][column] > 0 };
            let color = if column == step { text_color } else if active { job.palette.accent }
                else { job.palette.background.mix(text_color, 0.09) };
            let x = grid_x + label_width + gap + column as i32 * (pad + gap);
            rounded_rect(buffer, width, height, x, y, pad, pad, color);
        }
    }
    let footer_scale = (1..=label_scale).rev().find(|scale| {
        [OMARCHY_URL, PLUGIN_URL_FIRST, PLUGIN_URL_LAST, PLUGIN_URL_END]
            .iter().all(|line| text_width(line, *scale) <= w - margin * 2)
    }).unwrap_or(1);
    let footer_y = h * 80 / 100;
    for (index, line) in [OMARCHY_URL, PLUGIN_URL_FIRST, PLUGIN_URL_LAST, PLUGIN_URL_END].iter().enumerate() {
        let offset = if index == 0 { 0 } else { (index as i32 * 10 + 5) * footer_scale };
        draw_text(buffer, width, height, margin, footer_y + offset, line,
            footer_scale * 8, text_color, None);
    }
}

// /////////////////////////////////////////////////////////////////////////////
// Portrait video frame
//
// Arrange the sixteen steps vertically so the full pattern fits in one grid.
// The highlighted row follows the same playhead as the exported audio.
// /////////////////////////////////////////////////////////////////////////////

fn render_portrait_frame(
    job: &VideoJob, timeline: &Timeline, frame: usize, buffer: &mut Vec<u8>,
    width: usize, height: usize,
) {
    init_video_font(&job.font_family);
    buffer.resize(width * height * 3, 0);
    fill(buffer, job.palette.background);
    let w = width as i32;
    let h = height as i32;
    let margin = w * 7 / 100;
    let sample = ((frame as u64 * SAMPLE_RATE as u64) / FPS as u64) as usize % timeline.cycle_samples;
    let step = timeline.step_at(sample);
    let text_scale = (w / 270).max(1);
    let label_scale = (w / 300).max(1);
    let logo_scale = text_scale * 2;
    draw_text(buffer, width, height, margin, h * 5 / 100, "omaloop",
        logo_scale * 8, job.palette.accent, None);
    draw_text(buffer, width, height, margin, h * 5 / 100 + logo_scale * 11,
        "by @joshuaswarren", label_scale * 8, job.palette.foreground, None);
    let handle = job.handle.trim().trim_start_matches('@').trim_start();
    if !handle.is_empty() {
        let max_width = w - margin * 2 - text_width("omaloop", logo_scale) - label_scale * 4;
        let shown = fit_handle(&format!("@{handle}"), label_scale, max_width);
        let handle_color = if job.palette.accent.contrast_with(job.palette.background) >= 7.0 {
            job.palette.accent
        } else {
            job.palette.foreground
        };
        draw_text(buffer, width, height, w - margin - text_width(&shown, label_scale),
            h * 5 / 100, &shown, label_scale * 8, handle_color, Some(max_width));
    }

    let labels = ["KICK", "SNARE", "HAT", "OHAT", "BASS", "LEAD"];
    let gap = (w / 180).max(3);
    let pad = w * 7 / 100;
    let beat_gap = gap;
    let grid_width = 6 * pad + 5 * gap;
    let grid_x = (w - grid_width) / 2;
    let grid_y = h * 18 / 100;
    let small_scale = (w / 450).max(1);
    for (column, label) in labels.iter().enumerate() {
        let x = grid_x + column as i32 * (pad + gap) + (pad - text_width(label, small_scale)) / 2;
        draw_text(buffer, width, height, x, grid_y - small_scale * 12,
            label, small_scale * 8, job.palette.foreground, None);
    }
    for index in 0..16 {
        let y = grid_y + index as i32 * (pad + gap) + (index as i32 / 4) * beat_gap;
        let number = format!("{:02}", index + 1);
        let number_color = if index == step { job.palette.foreground } else {
            job.palette.background.mix(job.palette.foreground, 0.55)
        };
        draw_text(buffer, width, height, grid_x - gap * 2 - text_width(&number, small_scale),
            y + (pad - small_scale * 8) / 2, &number, small_scale * 8, number_color, None);
        for column in 0..6 {
            let active = if column < 4 { job.pattern.drums[column][index] } else { job.pattern.notes[column - 4][index] > 0 };
            let color = if index == step { job.palette.foreground } else if active {
                job.palette.accent
            } else { job.palette.background.mix(job.palette.foreground, 0.09) };
            let x = grid_x + column as i32 * (pad + gap);
            rounded_rect(buffer, width, height, x, y, pad, pad, color);
        }
    }
    let footer_scale = (1..=label_scale).rev().find(|scale| {
        [OMARCHY_URL, PLUGIN_URL_FIRST, PLUGIN_URL_LAST, PLUGIN_URL_END]
            .iter().all(|line| text_width(line, *scale) <= w - margin * 2)
    }).unwrap_or(1);
    let footer_y = h * 88 / 100;
    for (index, line) in [OMARCHY_URL, PLUGIN_URL_FIRST, PLUGIN_URL_LAST, PLUGIN_URL_END].iter().enumerate() {
        let offset = if index == 0 { 0 } else { (index as i32 * 10 + 5) * footer_scale };
        draw_text(buffer, width, height, margin, footer_y + offset, line,
            footer_scale * 8, job.palette.foreground, None);
    }
}

fn render_landscape_frame(
    job: &VideoJob,
    timeline: &Timeline,
    frame: usize,
    buffer: &mut Vec<u8>,
    width: usize,
    height: usize,
) {
    init_video_font(&job.font_family);
    buffer.clear();
    buffer.resize(width * height * 3, 0);
    let palette = &job.palette;
    let text_color = palette.foreground;
    let handle_color = if palette.accent.contrast_with(palette.background) >= 7.0 {
        palette.accent
    } else {
        text_color
    };
    fill(buffer, palette.background);
    let w = width as i32;
    let h = height as i32;
    let narrowest_width = w.min(h);
    let margin = (narrowest_width * 4 / 100).max(18);
    let text_scale = (narrowest_width / 270).max(1);
    let small_scale = (narrowest_width / 210).max(1);
    let text_area_width = narrowest_width - margin * 2;

    let vertical_shift = if job.aspect == "landscape" { -(h * 7 / 100) } else { 0 };
    let logo_y = h * 18 / 100 + vertical_shift;
    let logo = "omaloop";
    draw_text(
        buffer,
        width,
        height,
        margin,
        logo_y,
        logo,
        text_scale * 2 * 8,
        palette.accent,
        None,
    );
    draw_text(
        buffer,
        width,
        height,
        margin,
        logo_y + text_scale * 19,
        "by @joshuaswarren",
        small_scale * 8,
        text_color,
        None,
    );

    let handle = job.handle.trim().trim_start_matches('@').trim_start();
    if !handle.is_empty() {
        let handle = format!("@{handle}");
        let max_width = text_area_width - text_width(logo, text_scale * 2) - 2 * small_scale;
        let shown = fit_handle(&handle, small_scale, max_width);
        let text_width = text_width(&shown, small_scale);
        draw_text(
            buffer,
            width,
            height,
            w - margin - text_width,
            logo_y,
            &shown,
            small_scale * 8,
            handle_color,
            Some(max_width),
        );
    }

    let sample =
        ((frame as u64 * SAMPLE_RATE as u64) / FPS as u64) as usize % timeline.cycle_samples;
    let step = timeline.step_at(sample);
    let labels = ["KICK", "SNARE", "HAT", "OHAT", "BASS", "LEAD"];
    let label_w = labels
        .iter()
        .map(|label| text_width(label, small_scale))
        .max()
        .unwrap_or(0)
        + small_scale;
    let gap = (narrowest_width / 180).max(3);
    // Split the marketplace address at its slash to keep every character
    // legible on a portrait export without changing the destination.
    let footer_scale = (1..=small_scale)
        .rev()
        .find(|scale| {
            [OMARCHY_URL, PLUGIN_URL_FIRST, PLUGIN_URL_LAST, PLUGIN_URL_END]
                .iter()
                .all(|line| text_width(line, *scale) <= text_area_width)
        })
        .unwrap_or(1);
    let footer_color = if palette.muted.contrast_with(palette.background) >= 7.0 {
        palette.muted
    } else {
        text_color
    };
    let footer_y = h - margin - 43 * footer_scale + vertical_shift;
    let grid_gaps = 16 * gap;
    let grid_insets = margin * 2 + label_w + grid_gaps;
    let available_cell_w = ((w - grid_insets) / 16).max(1);

    // Keep the grid centered between the creator line and the credits.
    let grid_top = logo_y + text_scale * 19 + small_scale * 8 + gap * 2;
    let grid_bottom = footer_y - gap * 2;
    let grid_height_limit = (grid_bottom - grid_top).min(h * 40 / 100);
    let cell_h = available_cell_w.min((grid_height_limit - 5 * gap) / 6).max(1);
    let cell_w = cell_h;
    let grid_w = label_w + grid_gaps + 16 * cell_w;
    let grid_x = (w - grid_w) / 2;
    let grid_h = 6 * cell_h + 5 * gap;
    let grid_y = ((h - grid_h) / 2 + vertical_shift).clamp(grid_top, grid_bottom - grid_h);
    for (row, label) in labels.iter().enumerate() {
        let y = grid_y + row as i32 * (cell_h + gap);
        draw_text(
            buffer,
            width,
            height,
            grid_x,
            y + (cell_h - 7 * small_scale) / 2,
            label,
            small_scale * 8,
            text_color,
            Some(label_w),
        );
        for column in 0..16 {
            let is_on = if row < 4 {
                job.pattern.drums[row][column]
            } else {
                job.pattern.notes[row - 4][column] > 0
            };
            let color = if column == step {
                palette.foreground
            } else if is_on {
                palette.accent
            } else {
                palette.background.mix(palette.foreground, 0.09)
            };
            let x = grid_x + label_w + gap + column as i32 * (cell_w + gap);
            rounded_rect(buffer, width, height, x, y, cell_w, cell_h, color);
        }
    }

    draw_text(
        buffer,
        width,
        height,
        margin,
        footer_y,
        OMARCHY_URL,
        footer_scale * 8,
        footer_color,
        None,
    );
    draw_text(
        buffer,
        width,
        height,
        margin,
        footer_y + 15 * footer_scale,
        PLUGIN_URL_FIRST,
        footer_scale * 8,
        footer_color,
        None,
    );
    draw_text(
        buffer,
        width,
        height,
        margin,
        footer_y + 25 * footer_scale,
        PLUGIN_URL_LAST,
        footer_scale * 8,
        footer_color,
        None,
    );
    draw_text(
        buffer,
        width,
        height,
        margin,
        footer_y + 35 * footer_scale,
        PLUGIN_URL_END,
        footer_scale * 8,
        footer_color,
        None,
    );
}

fn write_ppm(path: &Path, width: usize, height: usize, buffer: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("preview path has no parent")?;
    fs::create_dir_all(parent).map_err(|e| format!("cannot create preview directory: {e}"))?;
    let file = File::create(path).map_err(|e| format!("cannot create preview: {e}"))?;
    let mut out = BufWriter::new(file);
    write!(out, "P6\n{} {}\n255\n", width, height).map_err(|e| e.to_string())?;
    out.write_all(buffer).map_err(|e| e.to_string())?;
    out.flush().map_err(|e| e.to_string())
}

fn ffmpeg_capabilities() -> Result<(), ExportFailure> {
    let output = Command::new("ffmpeg")
        .args(["-hide_banner", "-encoders"])
        .output()
        .map_err(|e| ExportFailure::Message(format!("FFmpeg is unavailable: {e}")))?;
    if !output.status.success() {
        return Err(ExportFailure::Message(
            "FFmpeg could not list encoders".into(),
        ));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let h264 = text
        .lines()
        .any(|line| line.split_whitespace().any(|word| word == "libx264"));
    let aac = text
        .lines()
        .any(|line| line.split_whitespace().any(|word| word == "aac"));
    if !h264 || !aac {
        return Err(ExportFailure::Message(format!(
            "FFmpeg needs software libx264 and AAC encoders (libx264={}, aac={})",
            h264, aac
        )));
    }
    Ok(())
}

fn diagnostic_tail(data: &Arc<Mutex<VecDeque<u8>>>) -> String {
    let bytes: Vec<u8> = data
        .lock()
        .map(|q| q.iter().copied().collect())
        .unwrap_or_default();
    String::from_utf8_lossy(&bytes)
        .trim()
        .chars()
        .rev()
        .take(1200)
        .collect::<String>()
        .chars()
        .rev()
        .collect()
}

fn ffmpeg_args(
    job: &VideoJob,
    timeline: &Timeline,
    audio: &Path,
    temp_output: &Path,
) -> (Vec<String>, usize) {
    let (width, height) = job.dimensions();
    // Ceil rather than round so the video stream never ends before the exact
    // rendered audio. The output `-t` below trims only the final partial frame.
    let frame_count =
        ((timeline.seconds() * job.repetitions as f64 * FPS as f64).ceil() as usize).max(1);
    let size = format!("{}x{}", width, height);
    let duration = format!("{:.9}", timeline.seconds() * job.repetitions as f64);
    let args = vec![
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
        "-nostdin".to_string(),
        // Keep FFmpeg's input queues bounded: the engine already provides a
        // single ordered frame stream and should never let a long export turn
        // into an in-memory frame sequence.
        "-thread_queue_size".to_string(),
        "1".to_string(),
        "-f".to_string(),
        "rawvideo".to_string(),
        "-pix_fmt".to_string(),
        "rgb24".to_string(),
        "-s".to_string(),
        size,
        "-r".to_string(),
        FPS.to_string(),
        "-i".to_string(),
        "-".to_string(),
        "-thread_queue_size".to_string(),
        "1".to_string(),
        "-i".to_string(),
        audio.to_string_lossy().to_string(),
        "-map".to_string(),
        "0:v:0".to_string(),
        "-map".to_string(),
        "1:a:0".to_string(),
        "-frames:v".to_string(),
        frame_count.to_string(),
        "-c:v".to_string(),
        "libx264".to_string(),
        "-threads".to_string(),
        "4".to_string(),
        "-preset".to_string(),
        "medium".to_string(),
        "-pix_fmt".to_string(),
        "yuv420p".to_string(),
        "-c:a".to_string(),
        "aac".to_string(),
        "-b:a".to_string(),
        "128k".to_string(),
        "-movflags".to_string(),
        "+faststart".to_string(),
        // An exact output duration avoids FFmpeg's `-shortest` read-ahead,
        // which otherwise buffers a long audio input while raw video is
        // encoded. Ceiled frame_count still guarantees the video is not the
        // shorter stream at this boundary.
        "-t".to_string(),
        duration,
        temp_output.to_string_lossy().to_string(),
    ];
    (args, frame_count)
}

fn spawn_ffmpeg(
    job: &VideoJob,
    timeline: &Timeline,
    audio: &Path,
    temp_output: &Path,
    flag: &AtomicBool,
    emit: &dyn Fn(Value),
) -> Result<(), ExportFailure> {
    ffmpeg_capabilities()?;
    let (args, frame_count) = ffmpeg_args(job, timeline, audio, temp_output);
    let mut command = Command::new("ffmpeg");
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            command.pre_exec(|| {
                // If the engine disappears during plugin unload, ffmpeg gets a
                // TERM from the kernel rather than becoming an orphan encoder.
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    let mut child = command
        .spawn()
        .map_err(|e| ExportFailure::Message(format!("could not start FFmpeg: {e}")))?;
    let stderr = child.stderr.take();
    let diagnostics = Arc::new(Mutex::new(VecDeque::with_capacity(16 * 1024)));
    let diagnostic_copy = diagnostics.clone();
    let reader = thread::spawn(move || {
        if let Some(stderr) = stderr {
            let mut reader = BufReader::new(stderr);
            let mut chunk = [0u8; 1024];
            while let Ok(n) = reader.read(&mut chunk) {
                if n == 0 {
                    break;
                }
                if let Ok(mut tail) = diagnostic_copy.lock() {
                    for byte in &chunk[..n] {
                        if tail.len() == 16 * 1024 {
                            tail.pop_front();
                        }
                        tail.push_back(*byte);
                    }
                }
            }
        }
    });
    let Some(mut stdin) = child.stdin.take() else {
        let _ = child.kill();
        let _ = child.wait();
        let _ = reader.join();
        return Err(ExportFailure::Message(
            "FFmpeg stdin was unavailable".into(),
        ));
    };
    let mut frame = Vec::new();
    for index in 0..frame_count {
        if cancelled(flag) {
            drop(stdin);
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(ExportFailure::Cancelled);
        }
        render_frame(job, timeline, index, &mut frame);
        if let Err(e) = stdin.write_all(&frame) {
            drop(stdin);
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(ExportFailure::Message(format!(
                "sending frame {index} to FFmpeg failed: {e}"
            )));
        }
        if index == 0 || index + 1 == frame_count || index % (frame_count / 100).max(1) == 0 {
            emit(
                json!({"event":"video_export_progress", "phase":"frames", "progress": 0.24 + (index + 1) as f32 / frame_count as f32 * 0.70, "frame": index + 1, "frames": frame_count}),
            );
        }
    }
    drop(stdin);
    let status = loop {
        if cancelled(flag) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err(ExportFailure::Cancelled);
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => thread::sleep(Duration::from_millis(20)),
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = reader.join();
                return Err(ExportFailure::Message(format!(
                    "waiting for FFmpeg failed: {e}"
                )));
            }
        }
    };
    let _ = reader.join();
    if !status.success() {
        let diagnostic = diagnostic_tail(&diagnostics);
        return Err(ExportFailure::Message(if diagnostic.is_empty() {
            format!("FFmpeg exited with {status}")
        } else {
            format!("FFmpeg exited with {status}: {diagnostic}")
        }));
    }
    Ok(())
}

fn reserve_output(path: &Path) -> Result<(), ExportFailure> {
    if path.exists() {
        return Err(ExportFailure::Message(format!(
            "refusing to overwrite existing file: {}",
            path.display()
        )));
    }
    let parent = path
        .parent()
        .ok_or_else(|| ExportFailure::Message("output path has no parent".into()))?;
    fs::create_dir_all(parent).map_err(|e| {
        ExportFailure::Message(format!(
            "cannot create output directory {}: {e}",
            parent.display()
        ))
    })?;
    if !parent.is_dir() {
        return Err(ExportFailure::Message(
            "output destination is not a directory".into(),
        ));
    }
    Ok(())
}

fn publish(temp: &Path, output: &Path) -> Result<(), ExportFailure> {
    if output.exists() {
        return Err(ExportFailure::Message(format!(
            "refusing to overwrite existing file: {}",
            output.display()
        )));
    }
    fs::hard_link(temp, output).map_err(|e| {
        ExportFailure::Message(format!("cannot publish completed video atomically: {e}"))
    })?;
    fs::remove_file(temp)
        .map_err(|e| ExportFailure::Message(format!("cannot finish atomic publish: {e}")))
}

fn emit_progress(tx: &Sender<Value>, value: Value) {
    let _ = tx.send(value);
}

fn probe_text(args: &[&str], path: &Path) -> Result<String, ExportFailure> {
    let output = Command::new("ffprobe")
        .args(args)
        .arg(path)
        .output()
        .map_err(|e| ExportFailure::Message(format!("ffprobe is unavailable: {e}")))?;
    if !output.status.success() {
        return Err(ExportFailure::Message(format!(
            "ffprobe rejected the completed video: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn has_fast_start_moov(path: &Path) -> Result<bool, ExportFailure> {
    let mut file = File::open(path)
        .map_err(|e| ExportFailure::Message(format!("cannot inspect completed video: {e}")))?;
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(4 * 1024 * 1024)
        .read_to_end(&mut bytes)
        .map_err(|e| ExportFailure::Message(format!("cannot inspect completed video: {e}")))?;
    let find = |needle: &[u8]| {
        bytes
            .windows(needle.len())
            .position(|window| window == needle)
    };
    Ok(match (find(b"moov"), find(b"mdat")) {
        (Some(moov), Some(mdat)) => moov < mdat,
        _ => false,
    })
}

fn validate_muxed(job: &VideoJob, timeline: &Timeline, path: &Path) -> Result<(), ExportFailure> {
    let (width, height) = job.dimensions();
    let video = probe_text(
        &[
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,width,height,pix_fmt,r_frame_rate",
            "-of",
            "csv=p=0",
        ],
        path,
    )?;
    let parts: Vec<&str> = video.split(',').collect();
    if parts.len() < 5
        || parts[0] != "h264"
        || parts[1] != width.to_string()
        || parts[2] != height.to_string()
        || parts[3] != "yuv420p"
        || parts[4] != "30/1"
    {
        return Err(ExportFailure::Message(format!(
            "completed video has unexpected video stream metadata: {video}"
        )));
    }
    let audio = probe_text(
        &[
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "default=nw=1:nk=1",
        ],
        path,
    )?;
    if audio.trim() != "aac" {
        return Err(ExportFailure::Message(format!(
            "completed video has unexpected audio codec: {audio}"
        )));
    }
    let format = probe_text(
        &[
            "-v",
            "error",
            "-show_entries",
            "format=format_name",
            "-of",
            "default=nw=1:nk=1",
        ],
        path,
    )?;
    if !format.contains("mp4") {
        return Err(ExportFailure::Message(format!(
            "completed file is not an MP4 container: {format}"
        )));
    }
    let duration = probe_text(
        &[
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
        ],
        path,
    )?
    .parse::<f64>()
    .map_err(|_| ExportFailure::Message("ffprobe returned no numeric duration".into()))?;
    let expected = timeline.seconds() * job.repetitions as f64;
    if !duration.is_finite() || (duration - expected).abs() > 1.0 / FPS as f64 + 0.01 {
        return Err(ExportFailure::Message(format!(
            "muxed duration {duration:.6}s is more than one frame from {expected:.6}s"
        )));
    }
    if !has_fast_start_moov(path)? {
        return Err(ExportFailure::Message(
            "completed MP4 does not have fast-start moov metadata".into(),
        ));
    }
    let decoded = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-i"])
        .arg(path)
        .args(["-f", "null", "-"])
        .output()
        .map_err(|e| ExportFailure::Message(format!("cannot decode completed video: {e}")))?;
    if !decoded.status.success() {
        return Err(ExportFailure::Message(format!(
            "completed video failed decode: {}",
            String::from_utf8_lossy(&decoded.stderr).trim()
        )));
    }
    Ok(())
}

fn cleanup_stale_job_dirs(parent: &Path) {
    let Ok(entries) = fs::read_dir(parent) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !name.starts_with(".omaloop-export-") || !path.is_dir() {
            continue;
        }
        let stale = entry
            .metadata()
            .ok()
            .and_then(|meta| meta.modified().ok())
            .and_then(|time| now.duration_since(time).ok())
            .map(|age| age > Duration::from_secs(24 * 60 * 60))
            .unwrap_or(false);
        if stale {
            let _ = fs::remove_dir_all(path);
        }
    }
}

fn parse_output_path(value: &Value) -> Result<PathBuf, String> {
    let output = value
        .get("outputPath")
        .and_then(Value::as_str)
        .ok_or("video job is missing its output path")?;
    let output_path = PathBuf::from(output);
    if !output_path.is_absolute() {
        return Err("video output path must be absolute".into());
    }
    if output_path
        .extension()
        .and_then(|x| x.to_str())
        .map(|x| x.eq_ignore_ascii_case("mp4"))
        != Some(true)
    {
        return Err("video output path must end in .mp4".into());
    }
    Ok(output_path)
}

fn run_job(
    job: VideoJob,
    output_path: &Path,
    flag: Arc<AtomicBool>,
    tx: Sender<Value>,
) -> Result<(f64, usize, usize, usize), ExportFailure> {
    reserve_output(output_path)?;
    let timeline = Timeline::new(&job.pattern, SAMPLE_RATE).map_err(ExportFailure::Message)?;
    let (width, height) = job.dimensions();
    let parent = output_path
        .parent()
        .ok_or_else(|| ExportFailure::Message("output path has no parent".into()))?;
    cleanup_stale_job_dirs(parent);
    let temp_root = parent.join(format!(".omaloop-export-{}", job.id));
    fs::create_dir(&temp_root).map_err(|e| {
        ExportFailure::Message(format!("cannot create per-job temporary directory: {e}"))
    })?;
    let wav = temp_root.join("audio.wav");
    let mp4 = temp_root.join("video.partial.mp4");
    let progress = |event| emit_progress(&tx, event);
    let result = (|| {
        let looped = render_loop(&job.pattern, &timeline, &flag, &progress)?;
        write_wav(&wav, &looped, job.repetitions, &flag, &progress)?;
        if cancelled(&flag) {
            return Err(ExportFailure::Cancelled);
        }
        spawn_ffmpeg(&job, &timeline, &wav, &mp4, &flag, &progress)?;
        if cancelled(&flag) {
            return Err(ExportFailure::Cancelled);
        }
        progress(json!({"event":"video_export_progress", "phase":"verify", "progress":0.96}));
        validate_muxed(&job, &timeline, &mp4)?;
        // Once publication begins, cancellation no longer changes the result.
        // This keeps a late cancel from reporting failure after an artifact is
        // already visible at the requested destination.
        if cancelled(&flag) {
            return Err(ExportFailure::Cancelled);
        }
        publish(&mp4, output_path)?;
        let frames =
            ((timeline.seconds() * job.repetitions as f64 * FPS as f64).ceil() as usize).max(1);
        Ok((
            timeline.seconds() * job.repetitions as f64,
            frames,
            width,
            height,
        ))
    })();
    let _ = fs::remove_dir_all(&temp_root);
    result
}

fn terminal_event(value: &Value) -> bool {
    matches!(
        value.get("event").and_then(Value::as_str),
        Some("video_exported" | "video_export_cancelled" | "error")
    )
}

/// `--render-video` reads one frozen JSON job, then continues reading JSON
/// commands so QML can cancel it without killing unrelated processes.
pub fn run_video_mode() -> i32 {
    let first = match std::io::stdin().lock().lines().next() {
        Some(Ok(line)) => line,
        _ => {
            eprintln!("video export needs one JSON job on stdin");
            return 2;
        }
    };
    let value: Value = match serde_json::from_str(&first) {
        Ok(value) => value,
        Err(e) => {
            eprintln!("invalid video job JSON: {e}");
            return 2;
        }
    };
    let job = match VideoJob::parse(&value) {
        Ok(job) => job,
        Err(e) => {
            eprintln!("invalid video job: {e}");
            return 2;
        }
    };
    let output_path = match parse_output_path(&value) {
        Ok(path) => path,
        Err(e) => {
            eprintln!("invalid video job: {e}");
            return 2;
        }
    };
    let job_id = job.id.clone();
    let flag = Arc::new(AtomicBool::new(false));
    let worker_flag = flag.clone();
    let worker_job_id = job_id.clone();
    let (events_tx, events_rx) = channel::<Value>();
    thread::spawn(move || {
        let _ = events_tx.send(json!({"event":"video_export_started", "jobId": worker_job_id}));
        match run_job(job, &output_path, worker_flag.clone(), events_tx.clone()) {
            Ok((duration, frames, width, height)) => {
                let _ = events_tx.send(json!({"event":"video_exported", "jobId": job_id, "duration": duration, "frames": frames, "width": width, "height": height}));
            }
            Err(ExportFailure::Cancelled) => {
                let _ = events_tx.send(json!({"event":"video_export_cancelled", "jobId": job_id}));
            }
            Err(ExportFailure::Message(message)) => {
                let _ =
                    events_tx.send(json!({"event":"error", "jobId": job_id, "message": message}));
            }
        }
    });
    let (commands_tx, commands_rx) = channel::<Value>();
    thread::spawn(move || {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines().flatten() {
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                let _ = commands_tx.send(value);
            }
        }
    });
    let mut done = false;
    while !done {
        if let Ok(event) = events_rx.recv_timeout(Duration::from_millis(20)) {
            println!("{event}");
            let _ = std::io::stdout().flush();
            done = terminal_event(&event);
        }
        while let Ok(command) = commands_rx.try_recv() {
            if command.get("cmd").and_then(Value::as_str) == Some("cancel")
                && command.get("jobId").and_then(Value::as_str)
                    == Some(value["jobId"].as_str().unwrap_or(""))
            {
                flag.store(true, Ordering::Relaxed);
            }
        }
    }
    0
}

pub fn run_preview_mode() -> i32 {
    let stdin = std::io::stdin();
    let line = match stdin.lock().lines().next() {
        Some(Ok(line)) => line,
        _ => {
            eprintln!("preview needs one JSON job on stdin");
            return 2;
        }
    };
    let value: Value = match serde_json::from_str(&line) {
        Ok(value) => value,
        Err(e) => {
            eprintln!("invalid preview JSON: {e}");
            return 2;
        }
    };
    let job = match VideoJob::parse(&value) {
        Ok(job) => job,
        Err(e) => {
            eprintln!("invalid preview job: {e}");
            return 2;
        }
    };
    let preview_path = value
        .get("previewPath")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| std::env::temp_dir().join(format!("omaloop-preview-{}.ppm", job.id)));
    let timeline = match Timeline::new(&job.pattern, SAMPLE_RATE) {
        Ok(timeline) => timeline,
        Err(e) => {
            eprintln!("preview timing failed: {e}");
            return 1;
        }
    };
    let (width, height) = job.dimensions();
    let mut buffer = Vec::new();
    render_frame(&job, &timeline, 0, &mut buffer);
    if let Err(e) = write_ppm(&preview_path, width, height, &buffer) {
        eprintln!("preview failed: {e}");
        return 1;
    }
    println!(
        "{}",
        json!({"event":"preview_ready", "jobId": job.id, "path": preview_path, "width": width, "height": height})
    );
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pattern(bpm: f32, swing: f32) -> Pattern {
        let mut p = Pattern::preset("y2k").unwrap();
        p.bpm = bpm;
        p.swing = swing;
        p
    }

    fn job_value() -> Value {
        json!({
            "jobId":"test",
            "pattern":Pattern::preset("y2k").unwrap().to_json(false),
            "repetitions":4,
            "aspect":"square",
            "quality":"standard"
        })
    }

    #[test]
    fn swing_changes_alternating_steps_but_not_cycle_duration() {
        let straight = Timeline::new(&pattern(120.0, 0.0), SAMPLE_RATE).unwrap();
        let swung = Timeline::new(&pattern(120.0, 1.0), SAMPLE_RATE).unwrap();
        assert_eq!(straight.cycle_samples, swung.cycle_samples);
        assert!(swung.starts[1] > straight.starts[1]);
        assert!(swung.starts[2] == straight.starts[2]);
    }

    #[test]
    fn loop_crossfade_is_periodic_at_repeat_boundary() {
        let p = pattern(300.0, 0.4);
        let timeline = Timeline::new(&p, SAMPLE_RATE).unwrap();
        let flag = AtomicBool::new(false);
        let looped = render_loop(&p, &timeline, &flag, &|_| {}).unwrap();
        let left = looped[looped.len() - 1];
        let right = looped[0];
        assert!(
            (left - right).abs() < 0.02,
            "boundary discontinuity exceeded the bounded renderer check: {left} vs {right}"
        );
    }

    #[test]
    fn rejects_repetitions_above_the_limit() {
        let mut value = job_value();
        value["repetitions"] = json!(65);
        assert_eq!(
            VideoJob::parse(&value).unwrap_err(),
            "repetitions must be an integer from 1 to 64"
        );
    }

    #[test]
    fn frame_uses_pattern_theme_and_playhead() {
        let mut value = job_value();
        value["palette"] = json!({"background":"#000000", "foreground":"#ffffff", "accent":"#ff0000", "muted":"#777777"});
        let job = VideoJob::parse(&value).unwrap();
        let timeline = Timeline::new(&job.pattern, SAMPLE_RATE).unwrap();
        let mut first = Vec::new();
        let mut later = Vec::new();
        render_frame(&job, &timeline, 0, &mut first);
        render_frame(&job, &timeline, 10, &mut later);
        assert_ne!(first, later, "the playhead should move");
        assert!(
            first.chunks_exact(3).any(|pixel| pixel == [255, 0, 0]),
            "theme accent should be visible"
        );
    }

    #[test]
    fn portrait_frame_changes_with_the_playhead() {
        let mut value = job_value();
        value["aspect"] = json!("portrait");
        let job = VideoJob::parse(&value).unwrap();
        let timeline = Timeline::new(&job.pattern, SAMPLE_RATE).unwrap();
        let mut first = Vec::new();
        let mut later = Vec::new();
        render_frame(&job, &timeline, 0, &mut first);
        render_frame(&job, &timeline, 10, &mut later);
        assert_ne!(first, later, "the portrait playhead should move");
    }

    #[test]
    fn non_integral_duration_uses_a_ceiled_video_frame_count() {
        let mut value = job_value();
        value["pattern"]["bpm"] = json!(143.0);
        value["repetitions"] = json!(4);
        let job = VideoJob::parse(&value).unwrap();
        let timeline = Timeline::new(&job.pattern, SAMPLE_RATE).unwrap();
        let (_, frames) = ffmpeg_args(
            &job,
            &timeline,
            Path::new("/tmp/a.wav"),
            Path::new("/tmp/a.mp4"),
        );
        assert_eq!(frames, 202);
    }
}
