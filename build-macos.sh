#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
version="${VERSION:-0.1.3}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $version" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/root"
app="$stage/Applications/Agent Watcher.app"
icon_source="assets/logo.png"
[[ -f "$icon_source" ]] || { echo "Missing application icon: $icon_source" >&2; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" dist
sdk="$(xcrun --sdk macosx --show-sdk-path)"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.agent-watcher</string>
<key>CFBundleName</key><string>Agent Watcher</string>
<key>CFBundleDisplayName</key><string>Agent Watcher</string>
<key>CFBundleExecutable</key><string>AgentWatcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

icon_images="$work/AppIcon"
mkdir -p "$icon_images"
for size in 16 32 64 128 256 512 1024; do
    sips -z "$size" "$size" "$icon_source" --out "$icon_images/$size.png" >/dev/null
done
/usr/bin/ruby -e '
  directory, output = ARGV
  types = {16=>"icp4", 32=>"icp5", 64=>"icp6", 128=>"ic07", 256=>"ic08", 512=>"ic09", 1024=>"ic10"}
  body = types.map do |size, type|
    png = File.binread(File.join(directory, "#{size}.png"))
    type + [png.bytesize + 8].pack("N") + png
  end.join
  File.binwrite(output, "icns" + [body.bytesize + 8].pack("N") + body)
' "$icon_images" "$app/Contents/Resources/AppIcon.icns"

for arch in arm64 x86_64; do
    swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" \
        Sources/Core/Domain.swift \
        Sources/Inputs/Codex/CodexUsage.swift \
        Sources/Inputs/Antigravity/AntigravityUsage.swift \
        Sources/App/Sentinel.swift \
        Sources/Inputs/Codex/HookRegistration.swift \
        Sources/Inputs/Antigravity/AntigravityIntegration.swift \
        -o "$work/app-$arch"
    swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" \
        Sources/Inputs/Codex/CodexHook.swift -o "$work/hook-$arch"
    swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" \
        Sources/Inputs/Antigravity/AntigravityHook.swift -o "$work/antigravity-hook-$arch"
done
lipo -create "$work/app-arm64" "$work/app-x86_64" -output "$app/Contents/MacOS/AgentWatcher"
lipo -create "$work/hook-arm64" "$work/hook-x86_64" -output "$app/Contents/MacOS/CodexHook"
lipo -create "$work/antigravity-hook-arm64" "$work/antigravity-hook-x86_64" -output "$app/Contents/MacOS/AntigravityHook"

if [[ -n "${APPLE_APP_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$APPLE_APP_IDENTITY" "$app/Contents/MacOS/CodexHook"
    codesign --force --options runtime --timestamp --sign "$APPLE_APP_IDENTITY" "$app/Contents/MacOS/AntigravityHook"
    codesign --force --options runtime --timestamp --sign "$APPLE_APP_IDENTITY" "$app"
else
    codesign --force --sign - "$app/Contents/MacOS/CodexHook"
    codesign --force --sign - "$app/Contents/MacOS/AntigravityHook"
    codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
pkg="dist/Agent-Watcher-$version.pkg"
if [[ -n "${APPLE_INSTALLER_IDENTITY:-}" ]]; then
    pkgbuild --root "$stage" --install-location / --identifier io.github.agent-watcher.pkg \
        --version "$version" --sign "$APPLE_INSTALLER_IDENTITY" "$pkg"
else
    pkgbuild --root "$stage" --install-location / --identifier io.github.agent-watcher.pkg \
        --version "$version" "$pkg"
fi
echo "Built: $pkg"
