#!/usr/bin/env bash
# Failure-injection coverage for the local video renderer. Every artifact lives
# below a temporary directory and successful failure cases must publish none.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin="$repo/engine/target/release/omaloop-engine"
for command_name in ffmpeg ffprobe python3; do
  if ! command -v "$command_name" >/dev/null; then
    echo "SKIP: $command_name is required for failure fixtures" >&2
    exit 77
  fi
done
if [[ ! -x "$bin" ]]; then
  echo "SKIP: build engine/target/release/omaloop-engine first" >&2
  exit 77
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp/base.json" <<'PY'
import json
import sys

job = {
    "jobId": "failure-base",
    "pattern": {
        "preset": "failure",
        "bpm": 120,
        "swing": 0.2,
        "volume": 0.8,
        "cutoff": 0.45,
        "detune": 0.5,
        "drive": 0.2,
        "sub": 0.5,
        "transpose": 0,
        "kick": [True, False, False, False, True, False, False, False, True, False, False, False, True, False, False, False],
        "snare": [False, False, False, False, True, False, False, False, False, False, False, False, True, False, False, False],
        "hat": [False, False, True, False, False, False, True, False, False, False, True, False, False, False, True, False],
        "ohat": [False] * 16,
        "bass": [45, 0, 45, 45, 0, 45, 0, 48, 45, 0, 45, 45, 0, 43, 0, 43],
        "lead": [57, 0, 57, 0, 60, 0, 57, 0, 64, 0, 62, 0, 60, 0, 59, 0],
    },
    "palette": {"background": "#11131a", "foreground": "#f0f1f5", "accent": "#55aaff", "muted": "#778899"},
    "aspect": "square",
    "quality": "standard",
    "repetitions": 1,
    "handle": "@failure",
    "outputPath": "/tmp/failure.mp4",
}
json.dump(job, open(sys.argv[1], "w"), separators=(",", ":"))
PY

make_job() {
  local name="$1" output="$2"
  local source="$tmp/$name.json"
  python3 - "$tmp/base.json" "$source" "$name" "$output" <<'PY'
import json
import sys
source, destination, job_id, output = sys.argv[1:]
job = json.load(open(source))
job["jobId"] = "failure-" + job_id
job["outputPath"] = output
json.dump(job, open(destination, "w"), separators=(",", ":"))
PY
  printf '%s\n' "$source"
}

expect_structured_error() {
  local label="$1" job="$2" path_env="$3" needle="$4" output="$5"
  local events="$tmp/$label.events" stderr="$tmp/$label.stderr"
  set +e
  env PATH="$path_env" "$bin" --render-video <"$job" >"$events" 2>"$stderr"
  local code=$?
  set -e
  grep -q '"event":"error"' "$events"
  grep -q "$needle" "$events" "$stderr" 2>/dev/null || {
    echo "FAIL: $label did not report '$needle' (exit $code)" >&2
    return 1
  }
  [[ ! -e "$output" ]]
  echo "PASS: $label (structured error, exit $code, no published output)"
}

# Missing FFmpeg: retain ffprobe for the later fixtures but deliberately omit
# ffmpeg from PATH.
missing_bin="$tmp/missing-bin"
mkdir -p "$missing_bin"
ln -s "$(command -v ffprobe)" "$missing_bin/ffprobe"
missing_output="$tmp/missing.mp4"
missing_job=$(make_job missing "$missing_output")
expect_structured_error missing "$missing_job" "$missing_bin" "FFmpeg is unavailable" "$missing_output"

# Incompatible FFmpeg: an encoder listing without both required software
# encoders must stop before a destination is created.
incompatible_bin="$tmp/incompatible-bin"
mkdir -p "$incompatible_bin"
cat >"$incompatible_bin/ffmpeg" <<'SH'
#!/bin/bash
printf ' V..... h264_nvenc hardware encoder\n'
printf ' A..... libfdk_aac external AAC encoder\n'
exit 0
SH
chmod +x "$incompatible_bin/ffmpeg"
incompatible_output="$tmp/incompatible.mp4"
incompatible_job=$(make_job incompatible "$incompatible_output")
expect_structured_error incompatible "$incompatible_job" "$incompatible_bin" "software libx264 and AAC" "$incompatible_output"

# The destination parent is a real read-only kernel filesystem. This injects
# destination setup failure without changing permissions on user data.
unwritable_output="/proc/omaloop-video-export-failure.mp4"
unwritable_job=$(make_job unwritable "$unwritable_output")
expect_structured_error unwritable "$unwritable_job" "$PATH" "cannot create per-job temporary directory" "$unwritable_output"

# Simulated low disk: the fake encoder advertises the expected encoders and
# then reports ENOSPC. A real disk-fill test is intentionally not performed.
low_disk_bin="$tmp/low-disk-bin"
mkdir -p "$low_disk_bin"
cat >"$low_disk_bin/ffmpeg" <<'SH'
#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == "-encoders" ]]; then
    printf ' V..... libx264 software H.264 encoder\n'
    printf ' A..... aac native AAC encoder\n'
    exit 0
  fi
done
printf 'No space left on device\n' >&2
exit 28
SH
chmod +x "$low_disk_bin/ffmpeg"
low_disk_output="$tmp/low-disk.mp4"
low_disk_job=$(make_job low-disk "$low_disk_output")
expect_structured_error low-disk "$low_disk_job" "$low_disk_bin" "FFmpeg\|sending frame" "$low_disk_output"

# Renderer startup failure is rejected before the worker starts.
set +e
printf '{}\n' | "$bin" --render-video >"$tmp/startup.events" 2>"$tmp/startup.stderr"
startup_code=$?
set -e
[[ "$startup_code" -eq 2 ]]
grep -q 'invalid video job' "$tmp/startup.stderr"
echo "PASS: renderer-startup (exit $startup_code, invalid job rejected)"

# A second JSON job sent while the first is active is ignored by the one-job
# renderer. The UI guard is exercised separately by the QML fixture.
python3 - "$bin" "$tmp/base.json" "$tmp/simultaneous.events" "$tmp/first.mp4" "$tmp/second.mp4" <<'PY'
import json
import os
import subprocess
import sys

binary, base_path, events_path, first_output, second_output = sys.argv[1:]
first = json.load(open(base_path))
second = json.load(open(base_path))
first["jobId"], first["outputPath"] = "failure-first", first_output
second["jobId"], second["outputPath"] = "failure-second", second_output
process = subprocess.Popen([binary, "--render-video"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
process.stdin.write(json.dumps(first) + "\n")
process.stdin.write(json.dumps(second) + "\n")
process.stdin.flush()
lines = []
for line in process.stdout:
    lines.append(line)
    if '"event":"video_exported"' in line or '"event":"error"' in line:
        break
process.stdin.close()
process.wait(timeout=30)
open(events_path, "w").writelines(lines)
assert sum('"event":"video_export_started"' in line for line in lines) == 1
assert sum('"event":"video_exported"' in line for line in lines) == 1
assert not os.path.exists(second_output)
PY
[[ -s "$tmp/first.mp4" ]]
[[ ! -e "$tmp/second.mp4" ]]
echo "PASS: simultaneous-second-export (one started/exported, second output absent)"

echo "PASS: renderer failure-injection suite; artifacts were temporary under $tmp"
