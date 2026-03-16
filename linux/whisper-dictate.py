#!/usr/bin/env python3
"""
WhisperDictate for Linux (Wayland)

Hold Super+Ctrl+X to record, release to stop, transcribes and injects text
into the focused input via wtype.

Usage:
    whisper-dictate.py start    — begin recording
    whisper-dictate.py stop     — stop recording, transcribe, and type text
    whisper-dictate.py toggle   — toggle recording on/off
    whisper-dictate.py install  — install openai-whisper package

Config: ~/.config/whisper-dictate/config.ini
"""

import configparser
import os
import signal
import subprocess
import sys
import time

CONFIG_DIR = os.path.expanduser("~/.config/whisper-dictate")
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.ini")
PID_FILE = "/tmp/whisper-dictate.pid"
AUDIO_FILE = "/tmp/whisper-dictate-recording.wav"
VALID_MODELS = ("base", "small")


def notify(message, timeout=2000):
    """Send a desktop notification."""
    try:
        subprocess.Popen(
            ["notify-send", "-t", str(timeout), "-a", "WhisperDictate", "WhisperDictate", message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass


def load_config():
    """Load config, creating default if it doesn't exist."""
    config = configparser.ConfigParser()
    config["whisper"] = {"model": "base"}

    if os.path.exists(CONFIG_PATH):
        config.read(CONFIG_PATH)
        model = config.get("whisper", "model", fallback="base")
        if model not in VALID_MODELS:
            print(f"Warning: invalid model '{model}' in config, using 'base'")
            config.set("whisper", "model", "base")
    else:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(CONFIG_PATH, "w") as f:
            f.write("# WhisperDictate Linux Configuration\n")
            f.write("# model options: base, small\n")
            f.write("#   base  — faster, ~140 MB download, good accuracy\n")
            f.write("#   small — slower, ~465 MB download, better accuracy\n\n")
            config.write(f)
        print(f"Created default config at {CONFIG_PATH}")

    return config


def find_whisper_cmd():
    """Find the whisper CLI command."""
    # Check common locations
    search = [
        os.path.expanduser("~/.local/bin/whisper"),
        "/usr/local/bin/whisper",
        "/usr/bin/whisper",
    ]
    for path in search:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path

    # Try which
    try:
        result = subprocess.run(
            ["which", "whisper"], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    return None


def ensure_whisper():
    """Auto-install openai-whisper if the whisper command is not found."""
    if find_whisper_cmd():
        return True

    print("whisper not found. Installing openai-whisper...")
    notify("Installing whisper... this may take a minute.", timeout=5000)

    try:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--user", "openai-whisper"],
            stdout=sys.stdout,
            stderr=sys.stderr,
        )
    except subprocess.CalledProcessError:
        print("Error: failed to install openai-whisper via pip.")
        print("Try manually: pip install openai-whisper")
        notify("Failed to install whisper. Run: pip install openai-whisper")
        return False

    if find_whisper_cmd():
        print("openai-whisper installed successfully.")
        notify("Whisper installed successfully.")
        return True

    print("Warning: pip install succeeded but 'whisper' command not found in PATH.")
    print("You may need to add ~/.local/bin to your PATH.")
    notify("Whisper installed but not in PATH. Add ~/.local/bin to PATH.")
    return False


def check_dependencies():
    """Check that required system tools are available."""
    missing = []
    for cmd in ["ffmpeg", "wtype", "notify-send"]:
        try:
            subprocess.run(
                ["which", cmd], capture_output=True, timeout=5
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            missing.append(cmd)
            continue
        else:
            result = subprocess.run(["which", cmd], capture_output=True, text=True, timeout=5)
            if result.returncode != 0:
                missing.append(cmd)

    if missing:
        print(f"Missing dependencies: {', '.join(missing)}")
        print("Install them with your package manager:")
        print(f"  sudo pacman -S {' '.join(missing)}    # Arch")
        print(f"  sudo apt install {' '.join(missing)}   # Debian/Ubuntu")
        return False
    return True


def is_recording():
    """Check if a recording session is active."""
    if not os.path.exists(PID_FILE):
        return False
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)  # Check if process is alive
        return True
    except (ProcessLookupError, ValueError, FileNotFoundError):
        # Stale PID file
        try:
            os.remove(PID_FILE)
        except FileNotFoundError:
            pass
        return False


def start_recording():
    """Start recording audio via ffmpeg."""
    if is_recording():
        notify("Already recording.")
        return

    # Remove old audio file
    if os.path.exists(AUDIO_FILE):
        os.remove(AUDIO_FILE)

    # Start ffmpeg recording — PulseAudio source (works with PipeWire too)
    try:
        proc = subprocess.Popen(
            [
                "ffmpeg", "-y",
                "-f", "pulse",
                "-i", "default",
                "-ar", "16000",
                "-ac", "1",
                "-c:a", "pcm_s16le",
                AUDIO_FILE,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        print("Error: ffmpeg not found.")
        notify("ffmpeg not found. Install it first.")
        return

    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))

    notify("Recording...", timeout=1500)


def stop_recording():
    """Stop recording, transcribe, and inject text via wtype."""
    if not os.path.exists(PID_FILE):
        notify("Not recording.")
        return

    # Read PID and kill ffmpeg
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
    except (ValueError, FileNotFoundError):
        return

    # Send SIGINT for clean ffmpeg shutdown (writes file headers properly)
    try:
        os.kill(pid, signal.SIGINT)
    except ProcessLookupError:
        pass

    # Wait for ffmpeg to exit (up to 3 seconds)
    for _ in range(30):
        try:
            os.kill(pid, 0)
            time.sleep(0.1)
        except ProcessLookupError:
            break

    # Clean up PID file
    try:
        os.remove(PID_FILE)
    except FileNotFoundError:
        pass

    # Verify audio file exists and has content
    if not os.path.exists(AUDIO_FILE):
        notify("No audio recorded.")
        return

    file_size = os.path.getsize(AUDIO_FILE)
    if file_size < 1000:  # Less than 1KB = basically empty
        notify("Recording too short.")
        try:
            os.remove(AUDIO_FILE)
        except FileNotFoundError:
            pass
        return

    notify("Transcribing...", timeout=5000)

    # Ensure whisper is installed
    if not ensure_whisper():
        return

    whisper_cmd = find_whisper_cmd()
    if not whisper_cmd:
        notify("whisper command not found.")
        return

    # Load config for model selection
    config = load_config()
    model = config.get("whisper", "model", fallback="base")

    # Run whisper CLI
    output_dir = "/tmp"
    try:
        result = subprocess.run(
            [
                whisper_cmd,
                AUDIO_FILE,
                "--model", model,
                "--language", "en",
                "--output_format", "txt",
                "--output_dir", output_dir,
            ],
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout
        )
    except subprocess.TimeoutExpired:
        notify("Transcription timed out.")
        return
    except FileNotFoundError:
        notify("whisper command not found.")
        return

    # Read transcript
    base_name = os.path.splitext(os.path.basename(AUDIO_FILE))[0]
    transcript_path = os.path.join(output_dir, f"{base_name}.txt")

    text = ""
    if os.path.exists(transcript_path):
        with open(transcript_path) as f:
            text = f.read().strip()
        os.remove(transcript_path)

    # Clean up audio file
    try:
        os.remove(AUDIO_FILE)
    except FileNotFoundError:
        pass

    if not text:
        notify("No speech detected.")
        return

    # Clean up whitespace
    text = " ".join(text.split())

    # Inject text into focused input via wtype
    try:
        subprocess.run(["wtype", "--", text], check=True, timeout=10)
        preview = text[:60] + ("..." if len(text) > 60 else "")
        notify(f"Typed: {preview}", timeout=2000)
    except FileNotFoundError:
        notify("wtype not found. Install it for text injection.")
        # Fall back to clipboard
        try:
            proc = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE)
            proc.communicate(input=text.encode())
            notify("Text copied to clipboard (wtype not found).")
        except FileNotFoundError:
            print(f"Transcription: {text}")
            notify("No way to inject text. Install wtype or wl-copy.")
    except subprocess.CalledProcessError:
        notify("wtype failed. Is a Wayland compositor running?")


def toggle_recording():
    """Toggle recording on/off."""
    if is_recording():
        stop_recording()
    else:
        start_recording()


def install_whisper():
    """Manually trigger whisper installation."""
    if find_whisper_cmd():
        print(f"whisper is already installed at: {find_whisper_cmd()}")
        return
    ensure_whisper()


def main():
    if len(sys.argv) < 2:
        print("WhisperDictate for Linux")
        print()
        print("Usage:")
        print("  whisper-dictate.py start    — begin recording")
        print("  whisper-dictate.py stop     — stop recording, transcribe, type text")
        print("  whisper-dictate.py toggle   — toggle recording on/off")
        print("  whisper-dictate.py install  — install openai-whisper")
        print("  whisper-dictate.py check    — check dependencies")
        print()
        print(f"Config: {CONFIG_PATH}")
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd == "start":
        start_recording()
    elif cmd == "stop":
        stop_recording()
    elif cmd == "toggle":
        toggle_recording()
    elif cmd == "install":
        install_whisper()
    elif cmd == "check":
        ok = check_dependencies()
        whisper_cmd = find_whisper_cmd()
        if whisper_cmd:
            print(f"whisper: {whisper_cmd}")
        else:
            print("whisper: NOT FOUND (run: whisper-dictate.py install)")
        config = load_config()
        model = config.get("whisper", "model", fallback="base")
        print(f"Model: {model}")
        print(f"Config: {CONFIG_PATH}")
        if ok and whisper_cmd:
            print("\nAll dependencies satisfied.")
        elif ok:
            print("\nSystem deps OK, but whisper needs to be installed.")
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
