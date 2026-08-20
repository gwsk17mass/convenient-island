#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
version="${1:-0.1.0}"
output_dir="$project_dir/build/releases"
dmg_name="Convenience-Island-v${version}-Apple-Silicon.dmg"
dmg_path="$output_dir/$dmg_name"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    echo "Версия должна быть в формате 0.1.0." >&2
    exit 1
fi

mkdir -p "$project_dir/build" "$output_dir"
if [[ -e "$dmg_path" || -e "$dmg_path.sha256" ]]; then
    echo "Файл выпуска уже существует: $dmg_path" >&2
    exit 1
fi

staging_dir="$(mktemp -d "$project_dir/build/dmg-stage.XXXXXX")"
cleanup() {
    if [[ "$staging_dir" == "$project_dir/build"/dmg-stage.* && -d "$staging_dir" ]]; then
        find "$staging_dir" -depth -delete
    fi
}
trap cleanup EXIT

app_dir="$staging_dir/Островок удобства.app"
contents_dir="$app_dir/Contents"
payload_dir="$staging_dir/payload"
executable="$contents_dir/MacOS/ConvenienceIsland"

cd "$project_dir"
swift build -c release

mkdir -p "$contents_dir/MacOS" "$payload_dir"
cp "$project_dir/.build/release/ConvenienceIsland" "$executable"
cp "$project_dir/AppBundle/Info.plist" "$contents_dir/Info.plist"
chmod 755 "$executable"

# The downloadable build intentionally excludes the 2+ GB local Whisper
# runtime and model. This keeps the release small and avoids publishing the
# local model cache. Other app features remain available.
strip -S "$executable"
codesign --force --options runtime --timestamp=none --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

ditto "$app_dir" "$payload_dir/Островок удобства.app"
ln -s /Applications "$payload_dir/Программы"
cp "$project_dir/AppBundle/Resources/Установка.txt" "$payload_dir/Установка.txt"

hdiutil create \
    -volname "Островок удобства" \
    -srcfolder "$payload_dir" \
    -format UDZO \
    "$dmg_path"

shasum -a 256 "$dmg_path" > "$dmg_path.sha256"
hdiutil verify "$dmg_path"

echo "$dmg_path"
