#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
version="${VERSION:-0.1.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION: $version" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/root"
app="$stage/Applications/Agent Watcher.app"
mkdir -p "$app/Contents/MacOS" dist
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
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

for arch in arm64 x86_64; do
    swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" Domain.swift Sentinel.swift HookRegistration.swift -o "$work/app-$arch"
    swiftc -O -sdk "$sdk" -target "$arch-apple-macosx13.0" CodexHook.swift -o "$work/hook-$arch"
done
lipo -create "$work/app-arm64" "$work/app-x86_64" -output "$app/Contents/MacOS/AgentWatcher"
lipo -create "$work/hook-arm64" "$work/hook-x86_64" -output "$app/Contents/MacOS/CodexHook"

if [[ -n "${APPLE_APP_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$APPLE_APP_IDENTITY" "$app/Contents/MacOS/CodexHook"
    codesign --force --options runtime --timestamp --sign "$APPLE_APP_IDENTITY" "$app"
else
    codesign --force --sign - "$app/Contents/MacOS/CodexHook"
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
