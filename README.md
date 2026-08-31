# FLAC2MP3

Small native macOS utility for converting a FLAC music library to MP3 with FFmpeg.

## Features

- Defaults to `/Volumes/MUSIK 2026`.
- Recursively scans subfolders by default, with a non-recursive option.
- Converts ordinary FLAC files to a same-folder MP3 with the same basename.
- Reads matching CUE sheets and creates separate tagged tracks named `01 - Artist - Title.mp3`.
- Skips existing outputs one track at a time, so interrupted albums can be resumed safely.
- Looks up missing metadata through MusicBrainz and downloads the release front cover from the Cover Art Archive.
- Preserves local metadata/artwork as a fallback and embeds the selected artwork in the MP3 without creating extra image files.
- Enforces the MusicBrainz rate limit and lets you choose the wait between files (1.0–60.0 seconds).
- Runs one FFmpeg process at a time, with live progress, a Cancel button, and a visible log.
- Stops on the first scan or conversion error and never changes the original FLAC/CUE files.

## Requirements

- macOS 13 or newer.
- FFmpeg with the `libmp3lame` encoder and its `ffprobe` companion. Homebrew installation:

  ```sh
  brew install ffmpeg
  ```

The app checks `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `/usr/bin/ffmpeg`, and the process `PATH` (and the equivalent `ffprobe` locations).

## Build and run

```sh
bash scripts/run-tests.sh
bash scripts/build-app.sh Release
open "build/Release/FLAC2MP3.app"
```

The local build is ad-hoc signed for personal use. The source repository intentionally does not contain the compiled app or music files.

## CUE behavior

CUE sheets are matched to FLAC files through their `FILE` entries. Track boundaries use `INDEX 01`; a track without a following boundary runs to the end of its source file. Same-folder cover images named `cover`, `folder`, or `front` are used when a source FLAC does not contain embedded artwork.

The default encoder is LAME V0 VBR, with 320 kbps CBR available in the quality selector. Existing MP3 files are never overwritten.

## MusicBrainz behavior

For each output that does not already exist, the app reads local FLAC/CUE tags and searches MusicBrainz for a uniquely high-confidence release. Embedded MusicBrainz release or recording IDs are preferred. Ambiguous results stop the run and list candidate releases so the local tags can be corrected. If no result is found, local metadata and artwork are used when they provide at least a title, artist, and cover.

MusicBrainz requests use the contactable User-Agent `FLAC2MP3/1.0 (jose@cruset.com)` and are serialized with a minimum one-second interval. Cover images are fetched from the Cover Art Archive using the selected release's `front-500` endpoint. Artist, album, title, year, and identifier fields are sent to MusicBrainz; audio files are never uploaded.

## Privacy

Conversion is local. FLAC, CUE, and generated MP3 files are not uploaded or sent to any service. Only textual tags and identifiers needed for MusicBrainz lookup leave the computer.
