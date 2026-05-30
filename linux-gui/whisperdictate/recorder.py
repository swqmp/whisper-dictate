"""Audio capture via ffmpeg (PulseAudio/PipeWire source).

Ported from the proven legacy CLI recorder, with its own PID/audio paths so it
never collides with the old whisper-dictate script running in parallel.
"""

from __future__ import annotations

import os
import signal
import subprocess
import time

PID_FILE = "/tmp/whisperdictate.pid"
AUDIO_FILE = "/tmp/whisperdictate-rec.wav"


def is_recording() -> bool:
    if not os.path.exists(PID_FILE):
        return False
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, ValueError, FileNotFoundError):
        try:
            os.remove(PID_FILE)
        except FileNotFoundError:
            pass
        return False


def start(device: str = "default") -> bool:
    if is_recording():
        return False
    if os.path.exists(AUDIO_FILE):
        try:
            os.remove(AUDIO_FILE)
        except FileNotFoundError:
            pass
    src = device if device and device != "default" else "default"
    try:
        proc = subprocess.Popen(
            ["ffmpeg", "-y", "-f", "pulse", "-i", src,
             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", AUDIO_FILE],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        return False
    with open(PID_FILE, "w") as f:
        f.write(str(proc.pid))
    return True


def stop() -> str | None:
    """Stop recording cleanly; return the wav path if usable, else None."""
    if not os.path.exists(PID_FILE):
        return None
    try:
        with open(PID_FILE) as f:
            pid = int(f.read().strip())
    except (ValueError, FileNotFoundError):
        return None

    try:
        os.kill(pid, signal.SIGINT)  # clean shutdown writes proper WAV headers
    except ProcessLookupError:
        pass

    for _ in range(30):  # wait up to ~3s for ffmpeg to flush + exit
        try:
            os.kill(pid, 0)
            time.sleep(0.1)
        except ProcessLookupError:
            break

    try:
        os.remove(PID_FILE)
    except FileNotFoundError:
        pass

    if not os.path.exists(AUDIO_FILE):
        return None
    if os.path.getsize(AUDIO_FILE) < 1000:  # effectively empty
        try:
            os.remove(AUDIO_FILE)
        except FileNotFoundError:
            pass
        return None
    return AUDIO_FILE
