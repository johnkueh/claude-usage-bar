#!/bin/sh
# Build Claude Usage.app and install it to ~/Applications.
set -eu
cd "$(dirname "$0")"

APP="Claude Usage.app"
BUILD="build"

rm -rf "$BUILD"
mkdir -p "$BUILD/$APP/Contents/MacOS"
cp Info.plist "$BUILD/$APP/Contents/Info.plist"
swiftc -O Sources/*.swift -o "$BUILD/$APP/Contents/MacOS/ClaudeUsage"
codesign --force --sign - "$BUILD/$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP"
cp -R "$BUILD/$APP" "$HOME/Applications/$APP"
echo "Installed: ~/Applications/$APP"
