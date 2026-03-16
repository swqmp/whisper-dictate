# WhisperDictate for Linux

Push-to-talk dictation for Wayland (Hyprland). Hold **Super + Ctrl + X** to record, release to transcribe and type. Uses OpenAI's Whisper for local transcription — no API key, no cloud, fully offline.

## Requirements

- Python 3.8+
- Wayland compositor (Hyprland recommended)
- PulseAudio or PipeWire (with PulseAudio compatibility)

### System dependencies

Install with your package manager:

**Arch Linux:**
```bash
sudo pacman -S ffmpeg wtype libnotify
```

**Debian/Ubuntu:**
```bash
sudo apt install ffmpeg wtype libnotify-bin
```

**Fedora:**
```bash
sudo dnf install ffmpeg wtype libnotify
```

## Install

### Quick install (recommended)

```bash
cd whisper-dictate/linux
chmod +x install.sh
./install.sh
```

This will:
1. Copy `whisper-dictate` to `~/.local/bin/`
2. Create default config at `~/.config/whisper-dictate/config.ini`
3. Install `openai-whisper` via pip if not present
4. Add the keybinding to `~/.config/hypr/keybindings.conf` (if it exists)

### Manual install

```bash
# Copy the script
cp linux/whisper-dictate.py ~/.local/bin/whisper-dictate
chmod +x ~/.local/bin/whisper-dictate

# Make sure ~/.local/bin is in your PATH
export PATH="$HOME/.local/bin:$PATH"

# Install whisper
pip install openai-whisper

# Verify
whisper-dictate check
```

## Hyprland Keybinding Setup

Add these lines to `~/.config/hypr/keybindings.conf`:

```conf
# WhisperDictate — hold Super+Ctrl+X to record, release to stop and transcribe
bind = SUPER CTRL, X, exec, ~/.local/bin/whisper-dictate start
bindr = SUPER CTRL, X, exec, ~/.local/bin/whisper-dictate stop
```

Then reload Hyprland config: `hyprctl reload`

**How it works:**
- `bind` fires on key **press** → starts recording
- `bindr` fires on key **release** → stops recording, transcribes, types the text

### Alternative: Toggle mode

If hold-to-record doesn't work well with your setup, use toggle mode instead (press once to start, press again to stop):

```conf
# WhisperDictate — press Super+Ctrl+X to toggle recording
bind = SUPER CTRL, X, exec, ~/.local/bin/whisper-dictate toggle
```

## Configuration

Edit `~/.config/whisper-dictate/config.ini`:

```ini
[whisper]
model = base
```

### Model options

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `base` | ~140 MB | Fast | Good for most dictation |
| `small` | ~465 MB | Slower | Better for complex speech |

The model downloads automatically on first use and is cached at `~/.cache/whisper/`.

## Usage

```bash
whisper-dictate start     # Begin recording
whisper-dictate stop      # Stop, transcribe, type text into focused input
whisper-dictate toggle    # Toggle recording on/off
whisper-dictate install   # Install openai-whisper package
whisper-dictate check     # Verify all dependencies
```

## How it works

1. **Record** — `ffmpeg` captures audio from your default PulseAudio/PipeWire input
2. **Transcribe** — OpenAI Whisper processes the audio locally (no internet needed after model download)
3. **Type** — `wtype` injects the transcribed text into whatever input is focused

Desktop notifications show status at each step.

## Replaces Voxtype

WhisperDictate replaces Voxtype with a simpler, lighter setup:
- No daemon running in the background
- No GUI, no tray icon — just a keybinding
- Local transcription only (private, no API keys)
- Single Python script, easy to modify

To fully remove Voxtype after switching:
```bash
# Stop and disable voxtype if it's running as a service
systemctl --user stop voxtype 2>/dev/null
systemctl --user disable voxtype 2>/dev/null

# Remove the binary/script
rm -f ~/.local/bin/voxtype

# Remove any Hyprland keybindings for voxtype from your config
```

## Troubleshooting

**"whisper not found"**
- Run `whisper-dictate install` or `pip install openai-whisper`
- Make sure `~/.local/bin` is in your PATH

**"ffmpeg not found"**
- Install ffmpeg: `sudo pacman -S ffmpeg` (Arch) or `sudo apt install ffmpeg` (Debian)

**"wtype not found"**
- Install wtype: `sudo pacman -S wtype` (Arch) or `sudo apt install wtype` (Debian)
- wtype only works on Wayland. If using X11, replace `wtype` with `xdotool type`

**Text not appearing in focused window**
- Make sure your Wayland compositor allows `wtype` to simulate input
- Some apps (like Electron apps) may need focus to be on an actual text input

**Recording starts but no transcription**
- Check that PulseAudio/PipeWire is working: `parecord --channels=1 /tmp/test.wav` then play it back
- Try a longer recording — very short clips may not transcribe

**Model download is slow**
- First run downloads the model (~140 MB for base, ~465 MB for small)
- Subsequent runs use the cached model from `~/.cache/whisper/`

## License

MIT. Built by NJ Developments.
