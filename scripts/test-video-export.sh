#!/usr/bin/env bash
# Bounded local integration fixture for the optional FFmpeg video path.
# It creates no repository artifacts; use exit 77 when FFmpeg is unavailable.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bin="$repo/engine/target/release/omaloop-engine"
if [[ ! -x "$bin" ]]; then
  echo "SKIP: build engine/target/release/omaloop-engine first" >&2
  exit 77
fi
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  echo "SKIP: ffmpeg and ffprobe are required for this fixture" >&2
  exit 77
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out="$tmp/omaloop fixture ü.mp4"
cat >"$tmp/job.json" <<EOF
{"jobId":"fixture-test","pattern":{"preset":"fixture","bpm":120,"swing":0.2,"volume":0.8,"cutoff":0.45,"detune":0.5,"drive":0.2,"sub":0.5,"transpose":0,"kick":[true,false,false,false,true,false,false,false,true,false,false,false,true,false,false,false],"snare":[false,false,false,false,true,false,false,false,false,false,false,false,true,false,false,false],"hat":[false,false,true,false,false,false,true,false,false,false,true,false,false,false,true,false],"ohat":[false,false,false,false,false,false,false,false,false,false,false,false,false,false,false,false],"bass":[45,0,45,45,0,45,0,48,45,0,45,45,0,43,0,43],"lead":[57,0,57,0,60,0,57,0,64,0,62,0,60,0,59,0]},"palette":{"background":"#11131a","foreground":"#f0f1f5","accent":"#55aaff","muted":"#778899"},"aspect":"square","quality":"standard","repetitions":1,"handle":"@test","outputPath":"$out"}
EOF

cat "$tmp/job.json" | "$bin" --render-video >"$tmp/events.json"
grep -q '"event":"video_exported"' "$tmp/events.json"
[[ -f "$out" ]]

python3 - "$out" <<'PY'
import pathlib, sys
chunk = pathlib.Path(sys.argv[1]).read_bytes()[:4 * 1024 * 1024]
assert 0 <= chunk.find(b"moov") < chunk.find(b"mdat"), "moov is not before mdat"
PY

# Render one old request and compare its decoded frames with the current job.
legacy_out="$tmp/legacy.mp4"
python3 - "$tmp/job.json" "$legacy_out" <<'PY_JOB' | "$bin" --render-video >"$tmp/legacy-events.json"
import json, sys
source, output = sys.argv[1:]
with open(source) as fixture:
    job = json.load(fixture)
job.update(style="spotlight", title="Fixture", credit=True,
           shareUrl="https://example.test/#fixture", themeName="Fixture")
job["palette"]["urgent"] = "#ff6688"
job["outputPath"] = output
print(json.dumps(job))
PY_JOB
grep -q '"event":"video_exported"' "$tmp/legacy-events.json"
ffmpeg -v error -i "$out" -map 0:v:0 -f framemd5 "$tmp/current.frames"
ffmpeg -v error -i "$legacy_out" -map 0:v:0 -f framemd5 "$tmp/legacy.frames"
cmp "$tmp/current.frames" "$tmp/legacy.frames"

# A second attempt with the same path must fail rather than truncate/overwrite.
cat "$tmp/job.json" | "$bin" --render-video >"$tmp/duplicate-events.json" 2>&1
# The process reports the structured error over stdout and exits after the
# structured terminal event; it must not silently replace the first artifact.
grep -q 'refusing to overwrite existing file' "$tmp/duplicate-events.json"

# Cancellation must produce a terminal event and no published MP4.
python3 - "$tmp/job.json" "$tmp/cancel-job.json" "$tmp/cancel.mp4" <<'PY'
import json, sys
source, destination, output = sys.argv[1:]
job = json.load(open(source))
job["jobId"] = "fixture-cancel"
job["pattern"]["bpm"] = 40
job["repetitions"] = 64
job["outputPath"] = output
json.dump(job, open(destination, "w"), separators=(",", ":"))
PY
python3 - "$bin" "$tmp/cancel-job.json" "$tmp/cancel-events.json" <<'PY'
import json, subprocess, sys, time
binary, job_path, events_path = sys.argv[1:]
job = json.load(open(job_path))
process = subprocess.Popen([binary, "--render-video"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
process.stdin.write(json.dumps(job) + "\n")
process.stdin.flush()
lines = []
cancel_sent = False
for line in process.stdout:
    lines.append(line)
    # Wait until FFmpeg is receiving frames so this exercises cancellation
    # during encoding rather than only the audio-render phase.
    if not cancel_sent and '"phase":"frames"' in line:
        process.stdin.write(json.dumps({"cmd": "cancel", "jobId": job["jobId"]}) + "\n")
        process.stdin.flush()
        cancel_sent = True
    if "video_export_cancelled" in line or '"event":"error"' in line:
        break
assert cancel_sent, "fixture never reached FFmpeg frame encoding"
open(events_path, "w").writelines(lines)
process.wait(timeout=10)
PY
grep -q 'video_export_cancelled' "$tmp/cancel-events.json"
[[ ! -e "$tmp/cancel.mp4" ]]

echo "PASS: fast-start export, legacy job, overwrite protection, and cancellation"
