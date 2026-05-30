"""GGML model registry for the local whisper.cpp backend.

Mirrors the macOS app's model set and cache layout so both platforms pull the
same GGML files into ~/.cache/whisper.cpp.
"""

import os

CACHE_DIR = os.path.expanduser("~/.cache/whisper.cpp")

# Linux default is medium.en (Jamiah's pick — Corsair One has the headroom).
# The macOS default is base.en; the model set is otherwise identical.
DEFAULT_MODEL = "medium.en"

AVAILABLE_MODELS = ["tiny.en", "base.en", "small.en", "medium.en", "turbo"]

_MODEL_FILES = {
    "tiny.en": "ggml-tiny.en.bin",
    "base.en": "ggml-base.en.bin",
    "small.en": "ggml-small.en.bin",
    "medium.en": "ggml-medium.en.bin",
    "turbo": "ggml-large-v3-turbo.bin",
}

# Download size (disk) — peak CPU RAM is roughly: tiny 0.4G, base 0.5G,
# small 1.0G, medium 2.6G, turbo 4.5G.
MODEL_SIZES = {
    "tiny.en": "~75 MB",
    "base.en": "~140 MB",
    "small.en": "~465 MB",
    "medium.en": "~1.5 GB",
    "turbo": "~1.6 GB",
}

_BASE_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"


def model_filename(model: str) -> str:
    return _MODEL_FILES.get(model, f"ggml-{model}.bin")


def model_path(model: str) -> str:
    return os.path.join(CACHE_DIR, model_filename(model))


def model_download_url(model: str) -> str:
    return _BASE_URL + model_filename(model)


def is_downloaded(model: str) -> bool:
    return os.path.isfile(model_path(model))
