"""Inject transcribed text into the focused field via wtype, or clipboard."""

import subprocess


def _clipboard(text: str) -> str:
    try:
        p = subprocess.Popen(["wl-copy"], stdin=subprocess.PIPE)
        p.communicate(input=text.encode())
        return "clipboard"
    except FileNotFoundError:
        return "none"


def inject(text: str, paste_mode: str = "paste") -> str:
    """Return 'typed', 'clipboard', or 'none'."""
    if paste_mode == "clipboard":
        return _clipboard(text)
    try:
        # "--" guards against text that begins with a dash
        subprocess.run(["wtype", "--", text], check=True, timeout=15)
        return "typed"
    except FileNotFoundError:
        return _clipboard(text)
    except subprocess.CalledProcessError:
        return _clipboard(text)
