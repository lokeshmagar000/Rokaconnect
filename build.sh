#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Rokaconnect.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Rokaconnect "$APP/Contents/MacOS/"
# system-wide now playing: open-source MediaRemoteAdapter (BSD-3)
[ -d Vendor/mediaremote-adapter/src ] || git clone --depth 1 https://github.com/ungive/mediaremote-adapter.git Vendor/mediaremote-adapter
[ -d Vendor/build/MediaRemoteAdapter.framework ] || ./build_adapter.sh
mkdir -p "$APP/Contents/Frameworks"
cp -R Vendor/build/MediaRemoteAdapter.framework "$APP/Contents/Frameworks/"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"
cp Vendor/mediaremote-adapter/LICENSE "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
cp AppIcon.icns "$APP/Contents/Resources/"
printf 'Share with Android uses message formats and constants from Google projects licensed under Apache License 2.0:\n  https://github.com/google/nearby\n  https://github.com/google/ukey2\n' > "$APP/Contents/Resources/NOTICE-Android-Sharing.txt"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Rokaconnect</string>
<key>CFBundleExecutable</key><string>Rokaconnect</string>
<key>CFBundleIdentifier</key><string>com.rokaconnect.app</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>18</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Rokaconnect sends and receives files with your iPhone and Android phones over your local network.</string>
<key>NSBonjourServices</key><array><string>_rokaportal._tcp</string><string>_FC9F5ED42C8A._tcp</string></array>
<key>NSMicrophoneUsageDescription</key><string>Rokaconnect routes an app’s audio through your equalizer. It never records you.</string>
<key>NSAudioCaptureUsageDescription</key><string>Rokaconnect applies your equalizer to an app’s audio.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Rokaconnect shows the weather where you are.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Rokaconnect shows AirPods and Galaxy Buds battery.</string>
<key>NSAppleEventsUsageDescription</key><string>Rokaconnect reads what is playing in Music and Spotify.</string>
</dict></plist>
P
codesign --force --sign - -r="designated => identifier \"com.rokaconnect.app\"" "$APP"
echo "Built $APP"
