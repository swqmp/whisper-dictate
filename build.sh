#!/bin/bash
# WhisperDictate Build Script
# Builds from source and installs to ~/Applications

set -e

SRCDIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Applications"

echo "Building WhisperDictate..."

cd "$SRCDIR"

# Build the binary
swiftc -o whisper-dictate-menubar WhisperDictate-MenuBar.swift \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Carbon

echo "Compiled successfully."

# Kill running instance
pkill -f "WhisperDictate.app/Contents/MacOS/WhisperDictate" 2>/dev/null || true

# Clean old app bundle
rm -rf WhisperDictate.app
mkdir -p "$INSTALL_DIR"

# Create app bundle
mkdir -p WhisperDictate.app/Contents/MacOS
mkdir -p WhisperDictate.app/Contents/Resources

# Copy binary
cp whisper-dictate-menubar WhisperDictate.app/Contents/MacOS/WhisperDictate

# Create Info.plist
cat > WhisperDictate.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WhisperDictate</string>
    <key>CFBundleIdentifier</key>
    <string>com.njdevelopments.whisperdictate</string>
    <key>CFBundleName</key>
    <string>WhisperDictate</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>WhisperDictate needs microphone access to record your voice for transcription.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>WhisperDictate needs to control System Events to paste transcribed text.</string>
</dict>
</plist>
EOF

# Install
rm -rf "$INSTALL_DIR/WhisperDictate.app"
cp -R WhisperDictate.app "$INSTALL_DIR/WhisperDictate.app"

# Also copy to /Applications if user wants system-wide
if [ -w "/Applications" ]; then
    rm -rf "/Applications/WhisperDictate.app"
    cp -R WhisperDictate.app "/Applications/WhisperDictate.app"
    echo "Installed to /Applications/WhisperDictate.app"
else
    echo "Installed to ~/Applications/WhisperDictate.app"
    echo "To install system-wide: sudo cp -R WhisperDictate.app /Applications/"
fi

# Cleanup build artifacts
rm -f whisper-dictate-menubar
rm -rf WhisperDictate.app

echo ""
echo "Done! Open WhisperDictate from Applications."
echo ""
echo "First launch:"
echo "  1. Grant Microphone permission when prompted"
echo "  2. Grant Accessibility permission (System Settings > Privacy & Security > Accessibility)"
echo "  3. Choose Local or Cloud transcription in the menu bar settings"
