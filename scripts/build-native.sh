#!/bin/sh
# Build the native macOS app: build/forge, and build/Sudoku Forge.app around it.
set -eu
cd "$(dirname "$0")/.."
ZIG="${ZIG:-zig}"
mkdir -p build

"$ZIG" build-obj core/solver.zig -O ReleaseFast -femit-bin=build/solver.o
"$ZIG" build-exe native/macos.zig build/solver.o -O ReleaseSmall \
  -framework AppKit -framework CoreGraphics -framework ImageIO -lobjc \
  -femit-bin=build/forge

APP="build/Sudoku Forge.app/Contents"
mkdir -p "$APP/MacOS"
cp build/forge "$APP/MacOS/forge"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sudoku Forge</string>
  <key>CFBundleIdentifier</key><string>net.jaenster.sudoku-forge</string>
  <key>CFBundleExecutable</key><string>forge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
echo "built build/forge ($(wc -c < build/forge | tr -d ' ') bytes)"
