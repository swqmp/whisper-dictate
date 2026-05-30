"""Local, dependency-free tests for the ported formatting + corrections logic.

Runs with plain python3 (no PySide6, no Mark) so the trickiest ported logic is
verified before it ever touches the GUI or the Corsair One.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from whisperdictate import formatting, corrections, models  # noqa: E402

_results = []


def check(name, got, expected):
    ok = got == expected
    _results.append(ok)
    print(("PASS " if ok else "FAIL "), name)
    if not ok:
        print("    expected:", repr(expected))
        print("    got:     ", repr(got))


# --- formatting: formal mode removes fillers, fixes caps + standalone i ---
check(
    "smart_format fillers + caps + i->I",
    formatting.smart_format("um so i went uh to the store. it was open"),
    "So I went to the store. It was open",
)

# --- formatting: casual mode keeps fillers, only tidies whitespace ---
check(
    "casual_format keeps fillers",
    formatting.casual_format("um so   i went\nto the store"),
    "um so i went to the store",
)

# --- corrections: longest-first, case-insensitive, disabled rule skipped ---
rules = [
    {"id": "1", "enabled": True, "spoken_phrase": "and J dev",
     "replacement_text": "NJ Developments", "created_at": 1.0},
    {"id": "2", "enabled": True, "spoken_phrase": "shopify",
     "replacement_text": "Shopify", "created_at": 2.0},
    {"id": "3", "enabled": False, "spoken_phrase": "chloe",
     "replacement_text": "Chloe", "created_at": 3.0},
]
check(
    "apply_correction_rules",
    corrections.apply_correction_rules(
        "i work at and J dev on shopify with chloe", rules),
    "i work at NJ Developments on Shopify with chloe",
)

# --- corrections must not fire on sub-word matches ---
check(
    "correction respects word boundary",
    corrections.apply_correction_rules("shopifying is not a word", rules),
    "shopifying is not a word",
)

# --- full pipeline: corrections THEN formal formatting ---
check(
    "format_transcript formal + corrections",
    formatting.format_transcript("um i use shopify", mode="formal", rules=rules),
    "I use Shopify",
)

# --- model registry sanity ---
check("default model", models.DEFAULT_MODEL, "medium.en")
check("model filename", models.model_filename("medium.en"), "ggml-medium.en.bin")
check(
    "model url",
    models.model_download_url("small.en"),
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
)

print()
passed = sum(_results)
print(f"{passed}/{len(_results)} passed")
sys.exit(0 if passed == len(_results) else 1)
