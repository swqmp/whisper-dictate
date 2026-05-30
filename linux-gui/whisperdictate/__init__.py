"""WhisperDictate for Linux (Wayland/Hyprland) — PySide6 GUI rewrite.

Full-parity port of the macOS menu-bar app:
  - local whisper.cpp backend (default) + OpenAI Whisper API + xAI Grok STT
  - Settings / History / Corrections windows, recording overlay
  - smart formatting, correction rules, transcription history

The trigger is a Hyprland keybind (Super+Ctrl+X) that signals the running
tray app over IPC — Wayland does not allow apps to grab global hotkeys.
"""

__version__ = "4.0.0-dev"
