# FLAC2MP3

Small native macOS utility for converting a FLAC music library to MP3 with FFmpeg.

## Features

- Defaults to `/Volumes/MUSIK 2026`.
- Recursively scans subfolders by default, with a non-recursive option.
- Converts ordinary FLAC files to a same-folder MP3 with the same basename.
- Reads matching CUE sheets and creates separate tagged tracks named `01 - Artist - Title.mp3`.
- Skips existing outputs one track at a time, so interrupted albums can be resumed safely.
- Preserves metadata and embeds FLAC or conventional `cover`, `folder`, or `front` artwork when available.
- Runs one FFmpeg process at a time, with live progress, a Cancel button, and a visible log.
- Stops on the first scan or conversion error and never changes the original FLAC/CUE files.

## Requirements

- macOS 13 or newer.
- FFmpeg with the `libmp3lame` encoder. Homebrew installation:

  ```sh
  brew install ffmpeg
  ```

The app checks `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `/usr/bin/ffmpeg`, and the process `PATH`.

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

## Privacy

Conversion is local. FLAC, CUE, and generated MP3 files are not uploaded or sent to any service.
