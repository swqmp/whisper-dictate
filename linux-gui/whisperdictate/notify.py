"""Desktop notifications via notify-send (no-op if unavailable)."""

import subprocess


def notify(message: str, timeout: int = 2000) -> None:
    try:
        subprocess.Popen(
            ["notify-send", "-t", str(timeout), "-a", "WhisperDictate",
             "WhisperDictate", message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except FileNotFoundError:
        pass
