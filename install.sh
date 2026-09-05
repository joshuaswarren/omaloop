#!/usr/bin/env bash
# Build the omaloop engine, register the omaloop:// link handler, and with --bind
# add SUPER+ALT+L to ~/.config/hypr/bindings.lua. Safe to re-run.
# Requires cargo (rustup.rs or `omarchy pkg add rustup`).
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

echo "==> registering omaloop:// links"
apps="$HOME/.local/share/applications"
mkdir -p "$apps"
chmod +x "$here/bin/omaloop-open"
cat > "$apps/omaloop.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=omaloop
Comment=Open a shared omaloop loop
Exec=$here/bin/omaloop-open %u
NoDisplay=true
Terminal=false
MimeType=x-scheme-handler/omaloop;
EOF
update-desktop-database "$apps" 2>/dev/null || true
xdg-mime default omaloop.desktop x-scheme-handler/omaloop
echo "    $(xdg-mime query default x-scheme-handler/omaloop)"

if [[ "${1:-}" == "--bind" ]]; then
  bindings="$HOME/.config/hypr/bindings.lua"
  if [[ -f "$bindings" ]] && grep -q "$plugin_id" "$bindings"; then
    echo "==> shortcut already bound in $bindings"
  else
    mkdir -p "$(dirname "$bindings")"
    printf '\n-- omaloop: drop-down groovebox\no.bind("SUPER + ALT + L", "omaloop", "omarchy-shell shell toggle %s")\n' "$plugin_id" >> "$bindings"
    echo "==> added SUPER+ALT+L to $bindings (reload Hyprland: hyprctl reload)"
  fi
else
  echo
  echo "To bind SUPER+ALT+L, re-run with --bind, or add to ~/.config/hypr/bindings.lua:"
  echo "  o.bind(\"SUPER + ALT + L\", \"omaloop\", \"omarchy-shell shell toggle $plugin_id\")"
fi

echo
echo "Toggle it now:  omarchy-shell shell toggle $plugin_id"
