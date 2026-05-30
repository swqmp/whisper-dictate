"""Transcript formatting — formal (clean) vs casual (raw) modes.

Faithful port of the macOS smartFormat / casualFormat / formatTranscript.
One intentional improvement: we trim leading/trailing whitespace BEFORE
capitalizing the first character, so a leading filler word ("um so...") no
longer leaves the first real word lowercase (a small bug in the macOS build).
"""

import re

from . import corrections

# Standalone filler words removed in formal mode (case-insensitive).
_FILLERS = [r"\bum\b", r"\buh\b", r"\bah\b", r"\bumm\b", r"\buhh\b", r"\bahh\b"]
_FILLER_RE = [re.compile(p, re.IGNORECASE) for p in _FILLERS]
_SENTENCE_CAP_RE = re.compile(r"([.!?])(\s+)(\w)")
_STANDALONE_I_RE = re.compile(r"\bi\b")  # case-sensitive: only lowercase i


def _collapse_spaces(s: str) -> str:
    while "  " in s:
        s = s.replace("  ", " ")
    return s


def smart_format(text: str) -> str:
    result = text.replace("\n", " ")
    result = _collapse_spaces(result)

    for rx in _FILLER_RE:
        result = rx.sub("", result)

    result = _collapse_spaces(result)
    result = result.replace(" ,", ",").replace(" .", ".").replace(",,", ",")

    result = _STANDALONE_I_RE.sub("I", result)

    result = result.strip()
    if result:
        result = result[0].upper() + result[1:]

    # Capitalize the first letter after sentence-ending punctuation.
    result = _SENTENCE_CAP_RE.sub(
        lambda m: m.group(1) + m.group(2) + m.group(3).upper(), result
    )
    return result


def casual_format(text: str) -> str:
    raw = text.replace("\n", " ")
    raw = _collapse_spaces(raw)
    return raw.strip()


def format_transcript(text: str, mode: str = "formal", rules: list = None) -> str:
    """Apply correction rules, then format per mode ('formal' or 'casual')."""
    corrected = corrections.apply_correction_rules(text, rules)
    if mode == "formal":
        return smart_format(corrected)
    return casual_format(corrected)
