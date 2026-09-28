#!/bin/bash
# Builds Whisperer.app into ~/Applications. Runs the core checks first; a failing check stops the install.
#   ./build.sh            checks + release build + install + relaunch
#   ./build.sh --no-open  same, without launching
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Applications/Whisperer.app"
# Assemble in a staging folder; the installed app is only replaced once everything below succeeded.
APP="$PWD/.build/stage/Whisperer.app"
BUNDLE_ID="uk.co.akasamedia.whisperer"
# A fixed signing identity keeps macOS permissions (Microphone, Accessibility) across rebuilds.
# Ad-hoc signing changes the signature every build and silently drops the grants.
IDENTITY="${WHISPERER_SIGN_IDENTITY:-35FE4B4DBEB6EB1977BF13D22CB0F2FB11F375C7}"   # "Skill Recorder Local Signing"

swift build --product CoreChecks >/dev/null   # debug: the checks use @testable
.build/debug/CoreChecks
swift build -c release --product Whisperer

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks/ggml-backends"
cp .build/release/Whisperer "$APP/Contents/MacOS/Whisperer"

# Carry our own copies of whisper.cpp + ggml (and ggml's GPU/CPU backend plugins), so a `brew upgrade`
# can never stop the app launching or change a struct under it. Every /opt/homebrew reference is
# rewritten to @rpath and the check below refuses to ship if one survives.
FW="$APP/Contents/Frameworks"
for lib in /opt/homebrew/opt/whisper.cpp/lib/libwhisper.1.dylib /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
           /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib /opt/homebrew/opt/libomp/lib/libomp.dylib; do
  cp -L "$lib" "$FW/"
done
cp -L /opt/homebrew/opt/ggml/libexec/libggml-*.so "$FW/ggml-backends/"
chmod u+w "$FW"/*.dylib "$FW"/ggml-backends/*.so
relink() {   # rewrite every Homebrew dependency of $1 to @rpath/<basename>
  otool -L "$1" | awk 'NR>1 && $1 ~ /^\/opt\/homebrew\// {print $1}' | while read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$1" 2>/dev/null
  done
}
for f in "$FW"/*.dylib; do install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null; relink "$f"; done
for f in "$FW"/ggml-backends/*.so; do relink "$f"; install_name_tool -add_rpath "@loader_path/.." "$f" 2>/dev/null || true; done
BIN="$APP/Contents/MacOS/Whisperer"
relink "$BIN"
while read -r rp; do install_name_tool -delete_rpath "$rp" "$BIN" 2>/dev/null || true; done \
  < <(otool -l "$BIN" | awk '/LC_RPATH/{f=1} f&&/ path /{if ($2 ~ /^\/opt\/homebrew\//) print $2; f=0}' | sort -u)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
if otool -L "$BIN" "$FW"/*.dylib "$FW"/ggml-backends/*.so | grep -q '/opt/homebrew/'; then
  echo "bundle still points at Homebrew:" >&2; otool -L "$BIN" "$FW"/*.dylib "$FW"/ggml-backends/*.so | grep '/opt/homebrew/' >&2; exit 1
fi

# Silero voice-activity model (885 KB): whisper skips silence on long recordings, which stops them looping.
# Fetched once into .build/vad and pinned by checksum, then bundled so the app never downloads it.
VAD_FILE="ggml-silero-v5.1.2.bin"
VAD_SHA="29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
mkdir -p .build/vad
if [ ! -f ".build/vad/$VAD_FILE" ]; then
  if [ -f "$HOME/Whisperer/models/$VAD_FILE" ]; then cp "$HOME/Whisperer/models/$VAD_FILE" .build/vad/
  else curl -fsSL -o ".build/vad/$VAD_FILE" "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_FILE"; fi
fi
if [ "$(shasum -a 256 ".build/vad/$VAD_FILE" | awk '{print $1}')" != "$VAD_SHA" ]; then
  echo "VAD model checksum mismatch; delete .build/vad and retry" >&2; rm -f ".build/vad/$VAD_FILE"; exit 1
fi
cp ".build/vad/$VAD_FILE" "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
.build/release/Whisperer --render-icon "$ICONSET"   # the staged copy is relinked and unsigned until the end
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Whisperer</string>
<key>CFBundleDisplayName</key><string>Whisperer</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>Whisperer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSMicrophoneUsageDescription</key><string>Whisperer listens while you dictate and turns your speech into text on this Mac.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL

if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  for f in "$FW"/*.dylib "$FW"/ggml-backends/*.so; do codesign --force --sign "$IDENTITY" "$f"; done
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with stable identity (permissions survive rebuilds)"
else
  for f in "$FW"/*.dylib "$FW"/ggml-backends/*.so; do codesign --force --sign - "$f"; done
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "WARNING: ad-hoc signed; macOS will ask for Microphone/Accessibility again after this build"
fi
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true
"$APP/Contents/MacOS/Whisperer" --render-icon "$(mktemp -d)/smoke.iconset"   # the bundled binary loads and runs

# Never swap the app out from under a recording: while one is being made its output.wav in
# ~/Whisperer/in-progress grows every ~100 ms. Wait (up to 10 minutes) while one was written in the last
# 10 s; leftovers from a crash are not "active" and are recovered by the next launch anyway.
RUNNING="^$DEST/Contents/MacOS/Whisperer"
for i in $(seq 1 300); do
  pgrep -f "$RUNNING" >/dev/null || break
  [ -n "$(find "$HOME/Whisperer/in-progress" -name output.wav -mtime -10s 2>/dev/null)" ] || break
  [ "$i" = 1 ] && echo "waiting for the current recording to finish..."
  sleep 2
done
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
# Wait for the old process to really exit (Quit can wait on a transcription), so we never relaunch it.
for _ in $(seq 1 60); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.5; done
if pgrep -f "$RUNNING" >/dev/null; then
  echo "Whisperer is still running after 30 s; quit it and run build.sh again (new build left at $APP)" >&2; exit 1
fi
rm -rf "$DEST"
mv "$APP" "$DEST"
echo "installed: $DEST"
[ "${1:-}" = "--no-open" ] || open "$DEST"
