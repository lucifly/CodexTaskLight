#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app_path='dist/CodexTaskLight.app'
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ ! -f Assets/AppIcon.icns \
  || Tools/DrawAppIcon.swift -nt Assets/AppIcon.icns \
  || Tools/BuildIcon.py -nt Assets/AppIcon.icns ]]; then
  python3 Tools/BuildIcon.py
fi
cp Assets/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
xcrun swiftc -parse-as-library \
  Sources/CodexTaskLight.swift Sources/LiveStatus.swift Sources/FloatingLight.swift \
  -module-cache-path "${TMPDIR:-/tmp}/pomodoro-swift-cache" \
  -file-prefix-map "$PWD=." -debug-prefix-map "$PWD=." \
  -target arm64-apple-macosx13.0 -O -warnings-as-errors \
  -o "$app_path/Contents/MacOS/CodexTaskLight" \
  -framework AppKit -framework SwiftUI -framework QuartzCore -framework CoreServices -lsqlite3
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexTaskLight</string>
<key>CFBundleIdentifier</key><string>local.codex.statuslight</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>24</string>
<key>CFBundleName</key><string>CodexTaskLight</string>
<key>CFBundleDisplayName</key><string>CodexTaskLight</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.4</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_path"
