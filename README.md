# WhisperDictate

Native macOS push-to-talk dictation app. Hold Right Option, speak, release to transcribe. Supports local (whisper.cpp) and cloud (OpenAI API) transcription.

## Features

- **Push-to-talk**: Hold Right Option key to record, release to transcribe
- **Two backends**: Local (whisper.cpp, free, private) or Cloud (OpenAI Whisper API, faster, more accurate)
- **Auto-paste**: Transcription gets typed into whatever app is focused
- **Menu bar app**: Lives in your menu bar, zero footprint
- **First-launch setup**: Walks you through picking a backend and entering your API key (if cloud)

## Requirements

- macOS 12.0 (Monterey) or later
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)

**For local transcription:**
```bash
brew install whisper-cpp ffmpeg
```

**For cloud transcription:**
- OpenAI API key (enter during first-launch setup)

## Install

```bash
git clone https://github.com/swqmp/whisper-dictate.git
cd whisper-dictate
chmod +x build.sh
./build.sh
```

## First Launch

1. Open WhisperDictate from Applications
2. Grant **Microphone** permission when prompted
3. Grant **Accessibility** permission (System Settings > Privacy & Security > Accessibility)
4. Choose your transcription backend (Local or Cloud)
5. If Cloud: enter your OpenAI API key

## Usage

1. Hold down **Right Option** key
2. Speak
3. Release to transcribe
4. Text appears in your active app

## Settings

Click the menu bar icon:

- **Backend**: Local (whisper.cpp) or Cloud (OpenAI API)
- **Whisper Model** (local): tiny, base, or small
- **Output Mode**: Paste, clipboard, or save to file
- **Show Notifications**: Toast on completion

## Troubleshooting

**"Transcription failed"**
- Local: make sure `whisper-cpp` is installed (`brew install whisper-cpp`)
- Cloud: check your API key in settings

**Auto-paste not working**
- Grant Accessibility permission in System Settings > Privacy & Security > Accessibility

**Hotkey not working**
- Make sure you're holding **Right** Option, not Left

## License

MIT. Built by NJ Developments.

## Credits

- [OpenAI Whisper](https://github.com/openai/whisper)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
