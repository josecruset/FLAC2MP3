import Darwin
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): return message }
    }
}

@main
struct FLAC2MP3TestRunner {
    static func main() async {
        do {
            try testCueParserReadsMetadataAndFrameBoundaries()
            try testScannerSplitsMatchingCueAndConvertsUnmatchedFLACOneToOne()
            try testScannerRejectsAmbiguousCueSheets()
            try await testFFmpegConversionProducesMP3AndLeavesSourceUntouched()
            try await testCueSplitConversionProducesTaggedTracks()
            print("FLAC2MP3 tests passed")
        } catch {
            fputs("FLAC2MP3 tests failed: \(error)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func testCueParserReadsMetadataAndFrameBoundaries() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cueURL = directory.appendingPathComponent("Album.cue")
        let cue = #"""
        REM DATE 2001
        REM GENRE "Rock"
        PERFORMER "The Artist"
        TITLE "The Album"
        FILE "Album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First Song"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second Song"
            INDEX 00 03:00:00
            INDEX 01 03:02:00
        """#
        try Data(cue.utf8).write(to: cueURL)

        let document = try CueParser.parse(url: cueURL)
        try require(document.albumMetadata.artist == "The Artist", "CUE artist was not parsed")
        try require(document.albumMetadata.album == "The Album", "CUE album was not parsed")
        try require(document.albumMetadata.genre == "Rock", "CUE genre was not parsed")
        try require(document.tracks.count == 2, "Expected two CUE tracks")
        try require(document.tracks[0].metadata.title == "First Song", "Track title was not parsed")
        try require(abs((document.tracks[0].endSeconds ?? -1) - 182) < 0.0001, "Track end boundary is wrong")
        try require(abs(document.tracks[1].startSeconds - 182) < 0.0001, "Track start boundary is wrong")
        try require(document.tracks[1].endSeconds == nil, "Final track should run to EOF")
    }

    private static func testScannerSplitsMatchingCueAndConvertsUnmatchedFLACOneToOne() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let albumDirectory = directory.appendingPathComponent("Artist/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumDirectory, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: albumDirectory.appendingPathComponent("cover.jpg"))
        try Data().write(to: albumDirectory.appendingPathComponent("Album.flac"))
        try Data().write(to: directory.appendingPathComponent("Single.flac"))
        let cueURL = albumDirectory.appendingPathComponent("Album.cue")
        let cue = #"""
        PERFORMER "Artist"
        TITLE "Album"
        FILE "Album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Two"
            INDEX 01 00:01:00
        """#
        try Data(cue.utf8).write(to: cueURL)

        let plan = try LibraryScanner().scan(rootURL: directory, recursive: true)
        try require(plan.jobs.count == 3, "Expected two split jobs and one ordinary job")
        try require(plan.jobs.contains { $0.outputURL.lastPathComponent == "01 - Artist - One.mp3" }, "First split output is wrong")
        try require(plan.jobs.contains { $0.outputURL.lastPathComponent == "02 - Artist - Two.mp3" }, "Second split output is wrong")
        try require(plan.jobs.contains { $0.outputURL.lastPathComponent == "Single.mp3" }, "Ordinary output is wrong")
        try require(plan.jobs.allSatisfy { $0.outputURL.deletingLastPathComponent() == $0.sourceURL.deletingLastPathComponent() }, "Outputs must share source folders")
        try require(plan.jobs.filter { $0.coverURL != nil }.count == 2, "Cover art was not attached to split jobs")
    }

    private static func testScannerRejectsAmbiguousCueSheets() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("Album.flac"))
        for name in ["First.cue", "Second.cue"] {
            let cue = directory.appendingPathComponent(name)
            let cueText = #"""
            FILE "Album.flac" WAVE
            TRACK 01 AUDIO
            TITLE "Song"
            INDEX 01 00:00:00
            """#
            try Data(cueText.utf8).write(to: cue)
        }

        do {
            _ = try LibraryScanner().scan(rootURL: directory, recursive: true)
            throw TestFailure.failed("Expected an ambiguous CUE error")
        } catch FLAC2MP3Error.ambiguousCue {
            return
        }
    }

    private static func testFFmpegConversionProducesMP3AndLeavesSourceUntouched() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg: URL
        do {
            ffmpeg = try await FFmpegLocator.locate()
        } catch {
            print("Skipping FFmpeg integration test: \(error)")
            return
        }
        let source = directory.appendingPathComponent("tone.flac")
        let generated = try await ProcessRunner().run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:a", "flac", source.path
        ])
        try require(generated.status == 0, "Could not generate FLAC fixture: \(generated.standardError)")
        let originalSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber

        let plan = try LibraryScanner().scan(rootURL: directory, recursive: true)
        let summary = try await ConversionService().convert(plan: plan, quality: .v0VBR) { _ in }
        try require(summary.converted == 1 && summary.skipped == 0, "Unexpected conversion summary")
        let output = directory.appendingPathComponent("tone.mp3")
        try require(FileManager.default.fileExists(atPath: output.path), "MP3 output was not created")
        let convertedSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        try require((convertedSize?.intValue ?? 0) > 0, "MP3 output is empty")
        let finalSourceSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        try require(finalSourceSize?.intValue == originalSize?.intValue, "Source FLAC was modified")
    }

    private static func testCueSplitConversionProducesTaggedTracks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg: URL
        do {
            ffmpeg = try await FFmpegLocator.locate()
        } catch {
            print("Skipping CUE FFmpeg integration test: \(error)")
            return
        }
        let source = directory.appendingPathComponent("disc.flac")
        let generated = try await ProcessRunner().run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:a", "flac", source.path
        ])
        try require(generated.status == 0, "Could not generate CUE FLAC fixture: \(generated.standardError)")
        let cueText = #"""
        PERFORMER "Cue Artist"
        TITLE "Cue Album"
        FILE "disc.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            INDEX 01 00:01:00
        """#
        try Data(cueText.utf8).write(to: directory.appendingPathComponent("disc.cue"))

        let plan = try LibraryScanner().scan(rootURL: directory, recursive: true)
        try require(plan.jobs.count == 2, "Expected two jobs from the CUE fixture")
        let summary = try await ConversionService().convert(plan: plan, quality: .cbr320) { _ in }
        try require(summary.converted == 2, "CUE tracks were not converted")
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("01 - Cue Artist - First.mp3").path), "First CUE MP3 is missing")
        try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("02 - Cue Artist - Second.mp3").path), "Second CUE MP3 is missing")
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FLAC2MP3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure.failed(message) }
    }
}
