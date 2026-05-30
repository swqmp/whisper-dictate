# WhisperDictate Linux — GUI Rewrite (PySide6) — Build Plan

**Status:** In progress (Phase 0 ~done, Phase 1 core logic started)
**Started:** 2026-05-30
**Goal:** Full-parity GUI rewrite of the Linux WhisperDictate so the Corsair One
(Mark / Omarchy / Hyprland) matches the macOS app, on a local whisper.cpp backend.

## Locked decisions
- Full GUI rewrite in **PySide6 (Qt)** — tray app + Settings/History/Corrections windows + recording overlay.
- **whisper.cpp local (CPU)** is the **default backend**. `aur/whisper.cpp 1.8.4-1`.
- Default model **medium.en**; **small.en** shipped as the fast fallback.
- Backends: local whisper.cpp / OpenAI Whisper API / xAI Grok STT (3, matches Mac; closes the old 2-backend gap).
- Trigger: **Super+Ctrl+X** via Hyprland keybind → signals the running app over IPC (Wayland forbids global hotkey grab). App writes/manages the bind.
- Vulkan GPU build kept as a later upgrade if CPU medium.en is too slow (GTX 1080 Ti present).
- Keep the old CLI (`~/.local/bin/whisper-dictate`) working until the GUI is proven, then retire it.

## Mark environment (verified 2026-05-30, ssh jamiahbartlett@100.121-via-tailscale 100.80.227.123)
- Arch Linux, kernel 7.0.9, GTX 1080 Ti. `nvcc` NOT installed (CUDA build would pull ~3GB; Vulkan avoids that).
- Deps present: ffmpeg, wtype, notify-send, wl-copy, python3, cmake, gcc, make, git, yay.
- whisper.cpp = **AUR `whisper.cpp` 1.8.4-1** (CPU). PySide6 = `pacman python-pyside6` + `qt6-wayland`.
- **Models downloaded** to `~/.cache/whisper.cpp/`: `ggml-medium.en.bin` (1.5G), `ggml-small.en.bin` (466M).
- Stale `~/.cache/whisper/base.pt` (old openai-whisper) removed. 813 GB free.
- **Hyprland already prepped by a prior session:**
  - `~/.config/hypr/hyprland.conf` (lines ~25-29): overlay window rules (float, pin, size 260x48, bottom-center) matching **window class `com.njdevelopments.whisperdictate`** → the Qt app MUST set its Wayland app_id / class to `com.njdevelopments.whisperdictate` so the overlay pill is placed automatically.
  - `~/.config/hypr/bindings.conf` (line 31): `bind = SUPER CTRL, X, exec, ~/.local/bin/whisper-dictate toggle` (currently points at the OLD CLI; repoint to the app IPC, or keep a thin shim).
  - User bindings live in `~/.config/hypr/bindings.conf` (sourced from hyprland.conf line 18). Omarchy defaults are in `~/.local/share/omarchy/default/hypr/` — DO NOT edit those; user overrides go in `~/.config/hypr/*.conf`.
- Currently running backend on Mark: `cloud_xai` (Grok), xAI key present. Local path was never functional (no whisper bin/openai-whisper) until this build.

## Repo layout (target — under projects/whisper-dictate/linux-gui/)
```
whisperdictate/
  __init__.py        done
  models.py          done  — GGML registry, paths, HF URLs, default medium.en
  corrections.py     done  — JSON-backed rule store + regex apply (port of CorrectionStore)
  formatting.py      done  — smart/casual format (port of smartFormat/casualFormat)
  config.py          TODO  — config.ini load/save (backend, model, device, paste_mode, formatting, recording_mode)
  recorder.py        TODO  — ffmpeg pulse capture start/stop (from old CLI)
  inject.py          TODO  — wtype primary, wl-copy fallback
  engine.py          TODO  — local whisper.cpp (whisper-cli) + cloud router
  cloud.py           TODO  — OpenAI Whisper API + xAI Grok STT
  history.py         TODO  — last-20 history + save-as-memo .md
  ipc.py             TODO  — unix socket so the Hyprland keybind reaches the running app
  hyprland.py        TODO  — read/write the Super+Ctrl+X bind, hyprctl reload
  app.py             TODO  — QSystemTrayIcon app, wires windows + engine + ipc
  ui/                TODO  — settings_window.py, history_window.py, corrections_window.py, overlay.py
main.py              TODO  — entry point
requirements.txt     TODO  — PySide6
README.md            TODO
tests/test_core.py   done  — 8/8 passing locally (formatting + corrections + models)
```

## Phases
- **Phase 0 — Prep on Mark. COMPLETE (2026-05-30).** whisper.cpp 1.8.4-1 installed, binary = `/usr/bin/whisper-cli` (matches Mac lookup). pyside6 6.11.1 + qt6-wayland installed (correct pkg was `pyside6`, NOT `python-pyside6`). Models down (medium.en 1.5G, small.en 466M). Smoke: whisper-cli + small.en ran exit 0, `[BLANK_AUDIO]` on silence (real-speech test pending live mic). base.pt cleaned, stale `~/.local/bin/whisper-dictated` python proc killed.
  - Cleanup-later: leftover `~/.local/bin/whisper` and `~/.local/bin/whisper-dictated` scripts still on disk; remove during integration. engine should prefer `whisper-cli` (resolves to /usr/bin/whisper-cli).
- **Phase 1 — Engine pipeline. ✅ VERIFIED WORKING 2026-05-30.** Jamiah confirmed live: hold Super+Ctrl+X → speak → release → text typed, tested in the TUI and Telegram, hold functionality good, all green. whisper.cpp local + medium.en + formatting/corrections in path. (History below = the build record.) Modules written + locally verified (compile + import chain + 8/8 tests): config, recorder (ffmpeg), inject (wtype/wl-copy), engine (whisper-cli + cloud routing), history, notify, cli. Deployed to Mark: package at `~/.local/share/whisperdictate/whisperdictate/`, launcher `~/.local/bin/whisperdictate`, keybind rewritten to HOLD mode (`bind` start / `bindr` stop → `~/.local/bin/whisperdictate`) in `~/.config/hypr/bindings.conf` (backup made), `hyprctl reload` succeeded. `whisperdictate check` green (backend local, medium.en present, whisper-cli + ffmpeg/wtype/wl-copy/notify-send all found). Old CLI left intact at `~/.local/bin/whisper-dictate`. **Remaining: Jamiah holds Super+Ctrl+X, speaks, confirms text lands.** Note: medium.en on CPU has real latency (~10-30s incl. model load) — expected, not a hang; small.en or Vulkan if too slow.
  - Tray GUI + IPC + Settings/History/Corrections windows + overlay = Phase 1b/2+ (engine modules above are what they'll import).
- **Phase 2 — Settings window.** backend/model(+download)/device/paste/formatting/recording-mode/launch-at-login (systemd user service).
- **Phase 3 — Formatting + Corrections windows.** wire the done modules into UI (add/edit/toggle/delete table).
- **Phase 4 — History window.** last-20 list, copy, save-as-memo.
- **Phase 5 — Recording overlay.** always-on-top pill (class com.njdevelopments.whisperdictate → existing Hyprland rules place it).
- **Phase 6 — Polish + ship.** E2E on Mark, packaging (.desktop, autostart, keybind writer), NVIDIA-Wayland env (QT_QPA_PLATFORM, etc.), docs (fix TOOLS.md "3 backends" error), commit + tag w/ Jamiah's OK, retire CLI.

## Needs Jamiah (sudo on Mark)
```
yay -S whisper.cpp
sudo pacman -S --needed python-pyside6 qt6-wayland
```
After install: confirm the whisper.cpp binary name (`whisper-cli` vs `main`) — engine.py adapts its lookup accordingly.

## Verification notes
- Pure-logic modules (formatting/corrections/models) are testable locally with `python3 tests/test_core.py` — no Qt, no Mark.
- engine/recorder/inject/UI need PySide6 + whisper.cpp on Mark to test — verify over SSH after the sudo installs.
- One intentional improvement over macOS: smart_format trims before capitalizing, so leading fillers ("um so…") don't leave the first word lowercase.
