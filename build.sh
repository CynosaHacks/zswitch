#!/bin/zsh
# Builds zswitch.app into ~/Applications
set -e
cd "$(dirname "$0")"

APP=~/Applications/zswitch.app

mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -o "$APP/Contents/MacOS/zswitch" \
  main.swift \
  -framework AppKit -framework CryptoKit -framework ServiceManagement -framework UserNotifications

cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP" 2>/dev/null || true

echo "Built $APP"
