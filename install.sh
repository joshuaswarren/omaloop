#!/usr/bin/env bash
# Build the omaloop engine and, with --bind, add SUPER+L to ~/.config/hypr/bindings.lua.
# Safe to re-run. Requires cargo (rustup.rs or `omarchy pkg add rustup`).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="io.github.joshuaswarren.omaloop"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust first: https://rustup.rs (or: omarchy pkg add rustup && rustup default stable)" >&2
  exit 1
fi

echo "==> building engine"
cargo build --release --manifest-path "$here/engine/Cargo.toml"
echo "    $here/engine/target/release/omaloop-engine"

if [[ "${1:-}" == "--bind" ]]; then
  bindings="$HOME/.config/hypr/bindings.lua"
  if [[ -f "$bindings" ]] && grep -q "$plugin_id" "$bindings"; then
    echo "==> SUPER+L already bound in $bindings"
  else
    mkdir -p "$(dirname "$bindings")"
    printf '\n-- omaloop: drop-down groovebox\no.bind("SUPER + L", "omaloop", "omarchy-shell shell toggle %s")\n' "$plugin_id" >> "$bindings"
    echo "==> added SUPER+L to $bindings (reload Hyprland: hyprctl reload)"
  fi
else
  echo
  echo "To bind SUPER+L, re-run with --bind, or add to ~/.config/hypr/bindings.lua:"
  echo "  o.bind(\"SUPER + L\", \"omaloop\", \"omarchy-shell shell toggle $plugin_id\")"
fi

echo
echo "Toggle it now:  omarchy-shell shell toggle $plugin_id"
