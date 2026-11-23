#!/usr/bin/env bash
# Render each supported aspect and quality combination.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin="$repo/engine/target/release/omaloop-engine"
for command_name in ffmpeg ffprobe python3 timeout; do
  if ! command -v "$command_name" >/dev/null; then
    echo "SKIP: $command_name is required for the video matrix" >&2
    exit 77
  fi
done
if [[ ! -x "$bin" ]]; then
  echo "SKIP: build engine/target/release/omaloop-engine first" >&2
  exit 77
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base="$tmp/base.json"

python3 - "$base" <<'PY'
import json
import sys

def blank_pattern():
    return {
        "preset": "matrix",
        "bpm": 120,
        "swing": 0.0,
        "volume": 0.8,
        "cutoff": 0.45,
        "detune": 0.5,
        "drive": 0.2,
        "sub": 0.5,
        "transpose": 0,
        "kick": [False] * 16,
        "snare": [False] * 16,
        "hat": [False] * 16,
        "ohat": [False] * 16,
        "bass": [0] * 16,
        "lead": [0] * 16,
    }

job = {
    "jobId": "matrix-base",
    "pattern": blank_pattern(),
    "palette": {
        "background": "#11131a",
        "foreground": "#f0f1f5",
        "accent": "#55aaff",
        "muted": "#778899",
    },
    "aspect": "square",
    "quality": "standard",
    "repetitions": 1,
    "handle": "@matrix",
    "outputPath": "/tmp/matrix.mp4",
}
json.dump(job, open(sys.argv[1], "w"), separators=(",", ":"))
PY

run_job() {
  local label="$1" bpm="$2" swing="$3" repetitions="$4" aspect="$5" quality="$6" content="${7:-dense}"
  local job="$tmp/$label.json" output="$tmp/$label.mp4" events="$tmp/$label.events"
  python3 - "$base" "$job" "$output" "$label" "$bpm" "$swing" "$repetitions" "$aspect" "$quality" "$content" <<'PY'
import json
import sys

source, destination, output, label, bpm, swing, repetitions, aspect, quality, content = sys.argv[1:]
job = json.load(open(source))
job["jobId"] = "matrix-" + label
job["outputPath"] = output
job["aspect"] = aspect
job["quality"] = quality
job["repetitions"] = int(repetitions)
job["pattern"]["bpm"] = float(bpm)
job["pattern"]["swing"] = float(swing)

if content == "dense":
    job["pattern"].update(
        kick=[True] * 16,
        snare=[i % 2 == 1 for i in range(16)],
        hat=[True] * 16,
        ohat=[i % 4 == 3 for i in range(16)],
        bass=[33 if i % 2 == 0 else 36 for i in range(16)],
        lead=[57 + (i % 4) * 2 for i in range(16)],
    )
json.dump(job, open(destination, "w"), separators=(",", ":"))
PY

  timeout 240s "$bin" --render-video <"$job" >"$events"
  grep -q '"event":"video_exported"' "$events"
  [[ -s "$output" ]]

  local expected
  case "$aspect/$quality" in
    portrait/standard) expected="h264,720,1280,yuv420p,30/1" ;;
    square/standard) expected="h264,720,720,yuv420p,30/1" ;;
    landscape/standard) expected="h264,1280,720,yuv420p,30/1" ;;
    portrait/high) expected="h264,1080,1920,yuv420p,30/1" ;;
    square/high) expected="h264,1080,1080,yuv420p,30/1" ;;
    landscape/high) expected="h264,1920,1080,yuv420p,30/1" ;;
    *) echo "FAIL: unknown matrix dimensions for $label" >&2; return 1 ;;
  esac
  local video_meta audio_meta duration expected_duration
  video_meta=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate -of csv=p=0 "$output")
  audio_meta=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$output")
  [[ "$video_meta" == "$expected" ]]
  [[ "$audio_meta" == "aac" ]]
  duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$output")
  expected_duration=$(awk -v bpm="$bpm" -v reps="$repetitions" 'BEGIN { printf "%.9f", 240 / bpm * reps }')
  awk -v actual="$duration" -v expected="$expected_duration" 'BEGIN { if (actual < expected - 0.06 || actual > expected + 0.06) exit 1 }'
  ffmpeg -hide_banner -loglevel error -i "$output" -f null -
  echo "PASS: $label ($content, ${bpm} BPM, swing ${swing}, ${repetitions} repeats, ${aspect}/${quality}, duration=${duration}s)"
}

# Cover timing and repetition limits in the same renders used to check dimensions.
run_job portrait-standard 40 0.0 1 portrait standard silent
run_job portrait-high 120 0.0 1 portrait high
run_job square-standard 300 1.0 64 square standard
run_job square-high 120 0.0 1 square high
run_job landscape-standard 143 0.2 4 landscape standard
run_job landscape-high 120 0.0 1 landscape high

echo "PASS: video export matrix; artifacts were temporary under $tmp"
