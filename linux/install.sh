#!/bin/bash
# WhisperDictate Linux — Install Script
# Installs the script and sets up Hyprland keybinding

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/whisper-dictate"
HYPR_KEYBINDS="$HOME/.config/hypr/keybindings.conf"

echo "Installing WhisperDictate for Linux..."

# Create directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"

# Copy script
cp "$SCRIPT_DIR/whisper-dictate.py" "$INSTALL_DIR/whisper-dictate"
chmod +x "$INSTALL_DIR/whisper-dictate"

# Create default config if it doesn't exist
if [ ! -f "$CONFIG_DIR/config.ini" ]; then
    cp "$SCRIPT_DIR/config.ini" "$CONFIG_DIR/config.ini"
    echo "Created config at $CONFIG_DIR/config.ini"
fi

# Check system dependencies
echo ""
echo "Checking dependencies..."
MISSING=""

for cmd in ffmpeg wtype notify-send; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    else
        echo "  $cmd: $(command -v "$cmd")"
    fi
done

if [ -n "$MISSING" ]; then
    echo ""
    echo "Missing:$MISSING"
    echo "Install them:"
    echo "  Arch:   sudo pacman -S$MISSING"
    echo "  Debian: sudo apt install$MISSING"
fi

# Check if whisper is installed
if command -v whisper &>/dev/null; then
    echo "  whisper: $(command -v whisper)"
else
    echo ""
    echo "whisper not found. Installing openai-whisper..."
    pip install --user openai-whisper || {
        echo "Auto-install failed. Try: pip install openai-whisper"
    }
fi

# Add Hyprland keybinding
echo ""
if [ -f "$HYPR_KEYBINDS" ]; then
    if grep -q "whisper-dictate" "$HYPR_KEYBINDS"; then
        echo "Hyprland keybinding already exists in $HYPR_KEYBINDS"
    else
        echo "" >> "$HYPR_KEYBINDS"
        echo "# WhisperDictate — hold Super+Ctrl+X to record, release to stop and transcribe" >> "$HYPR_KEYBINDS"
        echo "bind = SUPER CTRL, X, exec, $INSTALL_DIR/whisper-dictate start" >> "$HYPR_KEYBINDS"
        echo "bindr = SUPER CTRL, X, exec, $INSTALL_DIR/whisper-dictate stop" >> "$HYPR_KEYBINDS"
        echo "Added keybinding to $HYPR_KEYBINDS"
    fi
else
    echo "Hyprland keybindings file not found at $HYPR_KEYBINDS"
    echo "Add these lines to your Hyprland config manually:"
    echo ""
    echo "  bind = SUPER CTRL, X, exec, $INSTALL_DIR/whisper-dictate start"
    echo "  bindr = SUPER CTRL, X, exec, $INSTALL_DIR/whisper-dictate stop"
fi

echo ""
echo "Done! Installed to $INSTALL_DIR/whisper-dictate"
echo ""
echo "Make sure ~/.local/bin is in your PATH:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
echo ""
echo "Run 'whisper-dictate check' to verify everything is set up."
