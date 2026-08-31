#!/usr/bin/env bash
set -euo pipefail

configuration="${1:-Release}"
case "$configuration" in
    Debug)
        optimization_flags=(-Onone)
        ;;
    Release)
        optimization_flags=(-O -whole-module-optimization)
        ;;
    *)
        echo "Usage: bash scripts/build-app.sh [Debug|Release]" >&2
        exit 2
        ;;
esac

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
machine_architecture="$(uname -m)"
output_directory="$project_root/build/$configuration"
app_bundle="$output_directory/FLAC2MP3.app"
module_cache="${TMPDIR:-/tmp}/flac2mp3-module-cache"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/flac2mp3-build.XXXXXX")"
staged_app="$staging_root/FLAC2MP3.app"
staged_executable="$staged_app/Contents/MacOS/FLAC2MP3"
trap 'rm -rf -- "$staging_root"' EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$module_cache"
cp "$project_root/Info.plist" "$staged_app/Contents/Info.plist"

xcrun --sdk macosx swiftc \
    -parse-as-library \
    -module-name FLAC2MP3 \
    -module-cache-path "$module_cache" \
    -target "$machine_architecture-apple-macos13.0" \
    "${optimization_flags[@]}" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    "$project_root"/Sources/FLAC2MP3/*.swift \
    -o "$staged_executable"

codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

mkdir -p "$output_directory"
rm -rf -- "$app_bundle"
ditto "$staged_app" "$app_bundle"

signed=false
for attempt in 1 2 3 4 5; do
    xattr -cr "$app_bundle"
    if codesign --force --sign - "$app_bundle"; then
        xattr -cr "$app_bundle"
        if codesign --verify --deep --strict "$app_bundle"; then
            signed=true
            break
        fi
    fi
    sleep 0.2
done

if [[ "$signed" != true ]]; then
    echo "Could not produce a clean signed app bundle; Finder/FileProvider metadata kept returning." >&2
    exit 1
fi

echo "$app_bundle"
