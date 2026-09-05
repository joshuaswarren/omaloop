#!/usr/bin/env bash
# omaloop installer. Everything here is reversible with --uninstall.
#
#   install.sh            build the engine, register the omaloop:// link handler
#   install.sh --bind     also add SUPER+ALT+L to ~/.config/hypr/bindings.lua
#   install.sh --uninstall  remove the link handler and the binding (then: omarchy plugin remove)
#
# Needs cargo (rustup.rs). No sudo or pkexec is required. Nothing is downloaded
# except crates pinned in engine/Cargo.lock.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="io.github.joshuaswarren.omaloop"
apps="$HOME/.local/share/applications"
bindings="$HOME/.config/hypr/bindings.lua"
marker="-- omaloop: drop-down groovebox"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$apps/omaloop.desktop"
  update-desktop-database "$apps" 2>/dev/null || true
  echo "==> removed omaloop:// handler"
  if [[ -f "$bindings" ]] && grep -qF -e "$marker" "$bindings"; then
    sed -i "/^$marker\$/,/^o.bind(\"SUPER + ALT + L\", \"omaloop\"/d" "$bindings"
    echo "==> removed SUPER+ALT+L from $bindings"
  fi
  echo "Now: omarchy plugin remove $plugin_id"
  echo "Your loops stay in ~/.config/omaloop and ~/Music/omaloop; delete them yourself if you want them gone."
  exit 0
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust first: https://rustup.rs" >&2
  exit 1
fi

echo "==> building engine"
cargo build --release --locked --manifest-path "$here/engine/Cargo.toml"
echo "    $here/engine/target/release/omaloop-engine"

echo "==> registering omaloop:// links (so 'open in omaloop' works from a browser)"
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
  if [[ -f "$bindings" ]] && grep -q "$plugin_id" "$bindings"; then
    echo "==> shortcut already bound in $bindings"
  else
    mkdir -p "$(dirname "$bindings")"
    printf '\n%s\no.bind("SUPER + ALT + L", "omaloop", "omarchy-shell shell toggle %s")\n' "$marker" "$plugin_id" >> "$bindings"
    echo "==> added SUPER+ALT+L to $bindings (reload Hyprland: hyprctl reload)"
  fi
else
  echo
  echo "To bind SUPER+ALT+L, re-run with --bind, or add to ~/.config/hypr/bindings.lua:"
  echo "  o.bind(\"SUPER + ALT + L\", \"omaloop\", \"omarchy-shell shell toggle $plugin_id\")"
fi

echo
echo "Toggle it now:  omarchy-shell shell toggle $plugin_id"
