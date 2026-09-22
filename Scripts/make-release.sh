#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="${1:-1.0.0}"
product_name="Ajazz Keyboard"
bundle_name="Ajazz Keyboard.app"
dist_dir="$project_root/dist"
work_dir="$project_root/.build/release-packaging-$version"
app_dir="$work_dir/$bundle_name"
binary="$project_root/.build/apple/Products/Release/AK820Mac"

cd "$project_root"
rm -rf "$work_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$dist_dir"

swift build -c release --arch arm64 --arch x86_64
cp "$binary" "$app_dir/Contents/MacOS/AK820Mac"
sed "s/__VERSION__/$version/g" Packaging/Info.plist > "$app_dir/Contents/Info.plist"
cp Packaging/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"

# Ad-hoc signing keeps the local bundle structurally valid. Public releases
# should be signed and notarized with a Developer ID certificate instead.
codesign --force --sign - "$app_dir"

stage_dir="$work_dir/dmg-root"
mkdir -p "$stage_dir"
cp -R "$app_dir" "$stage_dir/$bundle_name"
ln -s /Applications "$stage_dir/Aplicativos"

dmg="$dist_dir/Ajazz-Keyboard-$version.dmg"
zip="$dist_dir/Ajazz-Keyboard-$version.zip"
rm -f "$dmg" "$zip"
hdiutil create -quiet -volname "$product_name" -srcfolder "$stage_dir" -ov -format UDZO "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip"

echo "Criados:"
echo "  $dmg"
echo "  $zip"
