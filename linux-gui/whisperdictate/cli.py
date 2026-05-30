"""Headless entry: start / stop / toggle / check.

This is the engine driver the Hyprland keybind calls. The Qt tray GUI (later
phases) will import the same recorder/engine/inject modules — this CLI is the
proven core, not a throwaway.
"""

import os
import sys

from . import config as config_mod
from . import engine, history, inject as inject_mod, models, recorder
from .notify import notify


def cmd_start(cfg):
    if recorder.is_recording():
        notify("Already recording.")
        return
    if recorder.start(cfg.get("device")):
        notify("Recording...", timeout=1500)
    else:
        notify("Could not start recording (is ffmpeg installed?).")


def cmd_stop(cfg):
    wav = recorder.stop()
    if not wav:
        notify("Not recording (or clip too short).")
        return
    notify("Transcribing...", timeout=4000)
    text, err = engine.transcribe(wav, cfg)
    try:
        os.remove(wav)
    except OSError:
        pass
    if err:
        notify(f"Error: {err}")
        print(err, file=sys.stderr)
        return
    if not text:
        notify("No speech detected.")
        return
    result = inject_mod.inject(text, cfg.get("paste_mode"))
    history.add(text)
    preview = text[:60] + ("..." if len(text) > 60 else "")
    if result == "typed":
        notify(f"Typed: {preview}")
    elif result == "clipboard":
        notify(f"Copied to clipboard: {preview}")
    else:
        notify("No way to inject text (install wtype or wl-copy).")


def cmd_toggle(cfg):
    if recorder.is_recording():
        cmd_stop(cfg)
    else:
        cmd_start(cfg)


def cmd_check(cfg):
    wbin = engine.find_whisper_cli()
    model = cfg.get("model")
    print(f"backend:    {cfg.get('backend')}")
    print(f"model:      {model}  (downloaded: {models.is_downloaded(model)})")
    print(f"model path: {models.model_path(model)}")
    print(f"formatting: {cfg.get('formatting')}   paste_mode: {cfg.get('paste_mode')}")
    print(f"whisper-cli: {wbin or 'NOT FOUND'}")
    for tool in ("ffmpeg", "wtype", "wl-copy", "notify-send"):
        import shutil
        print(f"  {tool}: {shutil.which(tool) or 'missing'}")


def main():
    cfg = config_mod.Config()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "toggle"
    actions = {
        "start": cmd_start,
        "stop": cmd_stop,
        "toggle": cmd_toggle,
        "check": cmd_check,
    }
    fn = actions.get(cmd)
    if not fn:
        print(f"unknown command: {cmd}", file=sys.stderr)
        print("usage: whisperdictate [start|stop|toggle|check]", file=sys.stderr)
        sys.exit(1)
    fn(cfg)


if __name__ == "__main__":
    main()
