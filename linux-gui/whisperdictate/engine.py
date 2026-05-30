"""Transcription engine: local whisper.cpp + OpenAI Whisper + xAI Grok.

Returns (final_text, error). final_text already has correction rules + the
selected formatting mode applied. Mirrors the macOS transcribe/transcribeCloud
routing.
"""

import json
import os
import subprocess

from . import config as config_mod
from . import formatting, models

XAI_STT_URL = "https://api.x.ai/v1/stt"
XAI_STT_MODEL = "grok-stt"
OPENAI_STT_URL = "https://api.openai.com/v1/audio/transcriptions"

_BLANK_MARKERS = {"[BLANK_AUDIO]", "[SILENCE]", "[ Silence ]", "(silence)"}


def find_whisper_cli():
    for p in ["/usr/bin/whisper-cli", "/usr/local/bin/whisper-cli",
              os.path.expanduser("~/.local/bin/whisper-cli")]:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    try:
        r = subprocess.run(["which", "whisper-cli"], capture_output=True,
                           text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def _read_key(path, env_var):
    k = os.environ.get(env_var, "").strip()
    if k:
        return k
    if os.path.exists(path):
        try:
            with open(path) as f:
                return (f.read().strip() or None)
        except OSError:
            return None
    return None


def _transcribe_local(wav, cfg):
    wbin = find_whisper_cli()
    if not wbin:
        return None, "whisper-cli not found (install whisper.cpp)"
    model = cfg.get("model")
    mpath = models.model_path(model)
    if not os.path.isfile(mpath):
        return None, f"model '{model}' not downloaded"
    out = "/tmp/whisperdictate-out"
    try:
        r = subprocess.run(
            [wbin, "-m", mpath, "-f", wav, "-l", "en", "-otxt", "-of", out, "-np"],
            capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        return None, "transcription timed out"
    if r.returncode != 0:
        return None, f"whisper-cli exit {r.returncode}: {r.stderr.strip()[:160]}"
    txt_path = out + ".txt"
    text = ""
    if os.path.exists(txt_path):
        with open(txt_path) as f:
            text = f.read().strip()
        try:
            os.remove(txt_path)
        except FileNotFoundError:
            pass
    if text in _BLANK_MARKERS:
        text = ""
    return text, None


def _curl_stt(wav, url, key, fields, text_key="text"):
    cmd = ["curl", "-sS", "--max-time", "45", "-X", "POST", url,
           "-H", f"Authorization: Bearer {key}"]
    for k, v in fields:
        cmd += ["-F", f"{k}={v}"]
    cmd += ["-F", f"file=@{wav}"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return None, "curl not found"
    except subprocess.TimeoutExpired:
        return None, "cloud request timed out"
    if r.returncode != 0:
        return None, f"curl exit {r.returncode}: {r.stderr.strip()[:120]}"
    try:
        payload = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None, f"invalid response: {r.stdout[:120]}"
    text = payload.get(text_key)
    if not isinstance(text, str) or not text.strip():
        return None, f"no text returned: {str(payload)[:120]}"
    return text.strip(), None


def _transcribe_xai(wav, cfg):
    key = _read_key(config_mod.XAI_KEY_PATH, "XAI_API_KEY")
    if not key:
        return None, "xAI key missing"
    return _curl_stt(wav, XAI_STT_URL, key,
                     [("model", XAI_STT_MODEL), ("language", "en")])


def _transcribe_openai(wav, cfg):
    key = _read_key(config_mod.OPENAI_KEY_PATH, "OPENAI_API_KEY")
    if not key:
        return None, "OpenAI key missing"
    return _curl_stt(wav, OPENAI_STT_URL, key,
                     [("model", "whisper-1"), ("language", "en")])


def transcribe(wav, cfg=None):
    """Transcribe a wav file. Returns (final_text, error)."""
    if cfg is None:
        cfg = config_mod.Config()
    backend = cfg.get("backend")
    if backend == "cloud_xai":
        raw, err = _transcribe_xai(wav, cfg)
    elif backend == "cloud_openai":
        raw, err = _transcribe_openai(wav, cfg)
    else:
        raw, err = _transcribe_local(wav, cfg)
    if err:
        return None, err
    if not raw:
        return "", None
    return formatting.format_transcript(raw, mode=cfg.get("formatting")), None
