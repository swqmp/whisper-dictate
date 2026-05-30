"""App settings, stored at ~/.config/whisper-dictate/settings.ini.

Uses its own settings.ini (NOT the old CLI's config.ini) so the legacy
whisper-dictate script keeps working untouched during the transition. The
xAI/OpenAI key files in the same dir are shared with the old setup.
"""

import configparser
import os

CONFIG_DIR = os.path.expanduser("~/.config/whisper-dictate")
SETTINGS_PATH = os.path.join(CONFIG_DIR, "settings.ini")
XAI_KEY_PATH = os.path.join(CONFIG_DIR, "xai-api-key")
OPENAI_KEY_PATH = os.path.join(CONFIG_DIR, "openai-api-key")

DEFAULTS = {
    "backend": "local",          # local | cloud_openai | cloud_xai
    "model": "medium.en",        # GGML model for the local backend
    "formatting": "formal",      # formal | casual
    "paste_mode": "paste",       # paste | clipboard
    "device": "default",         # pulse source name, or "default"
    "recording_mode": "hold",    # hold | toggle (informational; binds live in Hyprland)
}


class Config:
    def __init__(self):
        self.cp = configparser.ConfigParser()
        self.cp["whisper"] = dict(DEFAULTS)
        if os.path.exists(SETTINGS_PATH):
            try:
                self.cp.read(SETTINGS_PATH)
            except configparser.Error:
                pass
        if not self.cp.has_section("whisper"):
            self.cp.add_section("whisper")
        for k, v in DEFAULTS.items():
            if not self.cp.has_option("whisper", k):
                self.cp.set("whisper", k, v)

    def get(self, key):
        return self.cp.get("whisper", key, fallback=DEFAULTS.get(key))

    def set(self, key, value):
        self.cp.set("whisper", key, str(value))
        self.save()

    def save(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = SETTINGS_PATH + ".tmp"
        with open(tmp, "w") as f:
            self.cp.write(f)
        os.replace(tmp, SETTINGS_PATH)
