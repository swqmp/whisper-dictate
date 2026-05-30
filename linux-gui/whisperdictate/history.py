"""Transcription history (last 20), JSON-backed. Feeds the History window."""

import json
import os
import time

HISTORY_PATH = os.path.expanduser("~/.config/whisper-dictate/history.json")
MAX_ITEMS = 20


def load() -> list:
    try:
        with open(HISTORY_PATH) as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except (OSError, json.JSONDecodeError):
        return []


def add(text: str) -> None:
    if not text:
        return
    items = load()
    items.insert(0, {"text": text, "ts": time.time()})
    items = items[:MAX_ITEMS]
    os.makedirs(os.path.dirname(HISTORY_PATH), exist_ok=True)
    tmp = HISTORY_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(items, f, indent=2)
    os.replace(tmp, HISTORY_PATH)


def clear() -> None:
    try:
        os.remove(HISTORY_PATH)
    except FileNotFoundError:
        pass
