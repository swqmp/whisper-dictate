"""User correction rules — names, acronyms, and phrases Whisper gets wrong.

Faithful port of the macOS CorrectionStore + applyCorrectionRules logic, but
JSON-backed on disk instead of UserDefaults. Rules are applied case-insensitively,
longest-phrase-first, with whole-word boundaries that respect unicode letters.
"""

import json
import os
import re
import time
import uuid

CORRECTIONS_PATH = os.path.expanduser("~/.config/whisper-dictate/corrections.json")


def _load() -> list:
    try:
        with open(CORRECTIONS_PATH) as f:
            data = json.load(f)
            return data if isinstance(data, list) else []
    except (OSError, json.JSONDecodeError):
        return []


def _save(rules: list) -> None:
    os.makedirs(os.path.dirname(CORRECTIONS_PATH), exist_ok=True)
    tmp = CORRECTIONS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rules, f, indent=2)
    os.replace(tmp, CORRECTIONS_PATH)


def list_rules() -> list:
    return _load()


def add_rule(spoken_phrase: str, replacement_text: str, enabled: bool = True) -> dict:
    rule = {
        "id": str(uuid.uuid4()),
        "enabled": enabled,
        "spoken_phrase": spoken_phrase,
        "replacement_text": replacement_text,
        "created_at": time.time(),
    }
    rules = _load()
    rules.append(rule)
    _save(rules)
    return rule


def update_rule(rule_id: str, **changes) -> None:
    rules = _load()
    for r in rules:
        if r.get("id") == rule_id:
            r.update(changes)
            break
    _save(rules)


def delete_rule(rule_id: str) -> None:
    _save([r for r in _load() if r.get("id") != rule_id])


def toggle_rule(rule_id: str) -> None:
    rules = _load()
    for r in rules:
        if r.get("id") == rule_id:
            r["enabled"] = not r.get("enabled", True)
            break
    _save(rules)


def _pattern_for(phrase: str):
    """Build a whole-word, whitespace-tolerant regex for a spoken phrase.

    Mirrors the macOS correctionRegexPattern: each word is escaped and joined
    with \\s+, wrapped in unicode-aware word-boundary lookarounds. Python 3's
    \\w is unicode-aware, so (?<!\\w)/(?!\\w) stand in for [\\p{L}\\p{N}_].
    """
    parts = [p for p in re.split(r"\s+", phrase.strip()) if p]
    if not parts:
        return None
    body = r"\s+".join(re.escape(p) for p in parts)
    return r"(?<!\w)" + body + r"(?!\w)"


def apply_correction_rules(text: str, rules: list = None) -> str:
    if rules is None:
        rules = _load()

    active = [
        r for r in rules
        if r.get("enabled", True) and str(r.get("spoken_phrase", "")).strip()
    ]
    # Longest phrase first so multi-word rules win over their sub-phrases;
    # ties break by creation order (oldest first), matching the macOS app.
    active.sort(key=lambda r: (-len(r["spoken_phrase"]), r.get("created_at", 0)))

    result = text
    for r in active:
        pattern = _pattern_for(r["spoken_phrase"])
        if not pattern:
            continue
        replacement = r.get("replacement_text", "")
        # lambda replacement keeps the text literal (no backref interpretation)
        result = re.sub(pattern, lambda _m: replacement, result, flags=re.IGNORECASE)
    return result
