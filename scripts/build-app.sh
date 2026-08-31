#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c release --product Wallpaper

app_dir="$project_dir/dist/Wallpaper.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/Wallpaper" "$app_dir/Contents/MacOS/Wallpaper"
cp "Info.plist" "$app_dir/Contents/Info.plist"
cp "Assets/AppIcon.png" "$app_dir/Contents/Resources/AppIcon.png"
echo "Built $app_dir"
