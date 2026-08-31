#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_directory="$project_root/.build"
module_cache="${TMPDIR:-/tmp}/flac2mp3-tests-module-cache"
sdk_platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
mkdir -p "$build_directory"
mkdir -p "$module_cache"

xcrun --sdk macosx swiftc \
    -parse-as-library \
    -module-name FLAC2MP3Tests \
    -module-cache-path "$module_cache" \
    -target "$(uname -m)-apple-macos13.0" \
    -I "$sdk_platform/Developer/usr/lib" \
    -F "$sdk_platform/Developer/Library/Frameworks" \
    "$project_root/Sources/FLAC2MP3/Models.swift" \
    "$project_root/Sources/FLAC2MP3/CueParser.swift" \
    "$project_root/Sources/FLAC2MP3/LibraryScanner.swift" \
    "$project_root/Sources/FLAC2MP3/ProcessRunner.swift" \
    "$project_root/Sources/FLAC2MP3/ConversionService.swift" \
    "$project_root/Tests/FLAC2MP3Tests/FLAC2MP3Tests.swift" \
    -o "$build_directory/FLAC2MP3Tests"

"$build_directory/FLAC2MP3Tests"
