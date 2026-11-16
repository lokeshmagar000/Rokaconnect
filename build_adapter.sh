#!/bin/bash
# Builds the open-source MediaRemoteAdapter framework (BSD-3, github.com/ungive/mediaremote-adapter)
set -e
cd "$(dirname "$0")"
V=Vendor/mediaremote-adapter
OUT=Vendor/build/MediaRemoteAdapter.framework
rm -rf Vendor/build; mkdir -p "$OUT/Versions/A/Resources"
SRCS=(env get globals keys now_playing repeat seek send shuffle speed stream test)
FILES=()
for s in "${SRCS[@]}"; do FILES+=("$V/src/adapter/$s.m"); done
FILES+=("$V/src/private/MediaRemote.m" "$V/src/utility/Debounce.m" "$V/src/utility/helpers.m")
clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 -fobjc-arc -fvisibility=default \
  -I"$V/include" -I"$V/src" "${FILES[@]}" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$OUT/Versions/A/MediaRemoteAdapter"
cat > "$OUT/Versions/A/Resources/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundleName</key><string>MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
</dict></plist>
P
(cd "$OUT/Versions" && ln -sfn A Current)
(cd "$OUT" && ln -sfn Versions/Current/MediaRemoteAdapter MediaRemoteAdapter && ln -sfn Versions/Current/Resources Resources)
codesign --force --deep --sign - "$OUT"
echo "Built $OUT"
