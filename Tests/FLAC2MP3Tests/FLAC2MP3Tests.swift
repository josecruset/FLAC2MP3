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
            try await testMusicBrainzEnrichmentUsesMetadataAndArtwork()
            try await testMusicBrainzSearchSelectsUniqueRelease()
            try await testAmbiguousMusicBrainzSearchStopsEnrichment()
            try await testIgnoreMissingEnrichmentContinuesWithoutMetadataOrArtwork()
            try await testRateLimiterSpacesRequests()
            try await testInvalidRequestIntervalIsRejected()
            try await testDisabledMusicBrainzIgnoresRequestInterval()
            try await testFFmpegConversionProducesMP3AndLeavesSourceUntouched()
            try await testConversionCanOmitSourceMetadata()
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

    private static func testMusicBrainzEnrichmentUsesMetadataAndArtwork() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("song.flac")
        try Data().write(to: source)
        let releaseID = "11111111-1111-4111-8111-111111111111"
        let transport = RecordingHTTPTransport { request in
            if request.url?.path.contains("/front-500") == true {
                return HTTPResponse(statusCode: 200, headers: ["content-type": "image/jpeg"], data: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            }
            if request.url?.path.contains("/release/\(releaseID)") == true {
                let json = #"{"id":"11111111-1111-4111-8111-111111111111","title":"Online Album","date":"1984-01-01","artist-credit":[{"name":"Online Artist","artist":{"id":"22222222-2222-4222-8222-222222222222","name":"Online Artist"}}],"release-group":{"id":"33333333-3333-4333-8333-333333333333"},"genres":[{"name":"Synth-pop"}],"media":[{"position":1,"track-count":1,"tracks":[{"number":"1","title":"Online Title","artist-credit":[{"name":"Online Artist","artist":{"id":"22222222-2222-4222-8222-222222222222"}}],"recording":{"id":"44444444-4444-4444-8444-444444444444","title":"Online Title","isrcs":["US-AAA-84-00001"]}}]}]}"#
                return HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], data: Data(json.utf8))
            }
            throw TestFailure.failed("Unexpected MusicBrainz URL: \(request.url?.absoluteString ?? "nil")")
        }
        let probe = FixedMetadataProbe(snapshot: AudioMetadataSnapshot(
            metadata: TrackMetadata(
                artist: "Local Artist",
                albumArtist: "Local Artist",
                album: "Local Album",
                title: "Local Title",
                date: "1984",
                trackNumber: 1,
                trackTotal: 1,
                musicBrainzReleaseID: releaseID
            ),
            durationSeconds: 2,
            hasEmbeddedArtwork: false
        ))
        let enricher = MetadataEnricher(requestIntervalSeconds: 1.0, probe: probe, transport: transport)
        let job = ConversionJob(sourceURL: source, outputURL: directory.appendingPathComponent("song.mp3"))
        let enriched = try await enricher.enrich(job: job) { _ in }
        defer { enricher.cleanup() }
        try require(enriched.metadata?.artist == "Online Artist", "MusicBrainz artist was not applied")
        try require(enriched.metadata?.title == "Online Title", "MusicBrainz title was not applied")
        try require(enriched.metadata?.genre == "Synth-pop", "MusicBrainz genre was not applied")
        try require(enriched.metadata?.isrc == "US-AAA-84-00001", "MusicBrainz ISRC was not applied")
        try require(enriched.coverURL != nil && FileManager.default.fileExists(atPath: enriched.coverURL!.path), "Cover artwork was not downloaded")
        let requestCount = await transport.requestCount()
        let userAgent = await transport.firstUserAgent()
        try require(requestCount == 2, "Expected one release lookup and one artwork request")
        try require(userAgent == MusicBrainzClient.userAgent, "MusicBrainz User-Agent is wrong")
    }

    private static func testRateLimiterSpacesRequests() async throws {
        let limiter = MusicBrainzRateLimiter(intervalSeconds: 0.02)
        let start = DispatchTime.now().uptimeNanoseconds
        try await limiter.wait()
        try await limiter.wait()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        try require(elapsed >= 0.015, "Rate limiter did not space requests")
    }

    private static func testMusicBrainzSearchSelectsUniqueRelease() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("01 - Search Artist - Search Title.flac")
        let localCover = directory.appendingPathComponent("cover.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: localCover)
        let releaseID = "55555555-5555-4555-8555-555555555555"
        let transport = RecordingHTTPTransport { request in
            if request.url?.absoluteString.contains("/ws/2/release/?") == true {
                let json = #"{"releases":[{"id":"55555555-5555-4555-8555-555555555555","title":"Search Album","score":100,"date":"1990-01-01","artist-credit":[{"name":"Search Artist"}],"media":[{"track-count":1}]}]}"#
                return HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], data: Data(json.utf8))
            }
            if request.url?.path.contains("/front-500") == true {
                return HTTPResponse(statusCode: 404, headers: [:], data: Data())
            }
            if request.url?.path.contains("/release/\(releaseID)") == true {
                let json = #"{"id":"55555555-5555-4555-8555-555555555555","title":"Search Album","date":"1990-01-01","artist-credit":[{"name":"Search Artist"}],"media":[{"position":1,"track-count":1,"tracks":[{"number":"1","title":"Search Title","recording":{"id":"66666666-6666-4666-8666-666666666666","title":"Search Title"}}]}]}"#
                return HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], data: Data(json.utf8))
            }
            throw TestFailure.failed("Unexpected MusicBrainz search URL: \(request.url?.absoluteString ?? "nil")")
        }
        let probe = FixedMetadataProbe(snapshot: AudioMetadataSnapshot(
            metadata: TrackMetadata(artist: "Search Artist", albumArtist: "Search Artist", album: "Search Album", title: "Search Title", date: "1990", trackNumber: 1, trackTotal: 1),
            durationSeconds: 1,
            hasEmbeddedArtwork: false
        ))
        let enricher = MetadataEnricher(requestIntervalSeconds: 1.0, probe: probe, transport: transport)
        let job = ConversionJob(sourceURL: source, outputURL: directory.appendingPathComponent("search.mp3"), coverURL: localCover)
        let enriched = try await enricher.enrich(job: job) { _ in }
        defer { enricher.cleanup() }
        try require(enriched.metadata?.musicBrainzReleaseID == releaseID, "Unique MusicBrainz search result was not applied")
        try require(enriched.coverURL == localCover, "Local cover fallback was not used after a Cover Art Archive 404")
        let searchURL = await transport.firstURL(containing: "/ws/2/release/")
        try require(searchURL?.query?.contains("fmt=json") == true, "MusicBrainz search did not request JSON")
    }

    private static func testInvalidRequestIntervalIsRejected() async throws {
        do {
            _ = try await ConversionService().convert(
                plan: ConversionPlan(jobs: []),
                quality: .v0VBR,
                requestIntervalSeconds: 0.5,
                enrichMetadata: true
            ) { _ in }
            throw TestFailure.failed("Expected invalid request interval to be rejected")
        } catch FLAC2MP3Error.invalidRequestInterval {
            return
        }
    }

    private static func testDisabledMusicBrainzIgnoresRequestInterval() async throws {
        do {
            _ = try await FFmpegLocator.locate()
        } catch {
            print("Skipping disabled MusicBrainz interval test: \(error)")
            return
        }
        let summary = try await ConversionService().convert(
            plan: ConversionPlan(jobs: []),
            quality: .v0VBR,
            requestIntervalSeconds: 0.5,
            enrichMetadata: false
        ) { _ in }
        try require(summary.total == 0, "Disabled MusicBrainz conversion should accept an inactive interval")
    }

    private static func testAmbiguousMusicBrainzSearchStopsEnrichment() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ambiguous.flac")
        let transport = RecordingHTTPTransport { request in
            guard request.url?.absoluteString.contains("/ws/2/release/?") == true else {
                throw TestFailure.failed("Ambiguous lookup should stop before release/artwork requests")
            }
            let json = #"{"releases":[{"id":"77777777-7777-4777-8777-777777777777","title":"Same Album","score":100,"date":"2000-01-01","artist-credit":[{"name":"Same Artist"}],"media":[{"track-count":1}]},{"id":"88888888-8888-4888-8888-888888888888","title":"Same Album","score":100,"date":"2000-01-01","artist-credit":[{"name":"Same Artist"}],"media":[{"track-count":1}]}]}"#
            return HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], data: Data(json.utf8))
        }
        let probe = FixedMetadataProbe(snapshot: AudioMetadataSnapshot(
            metadata: TrackMetadata(artist: "Same Artist", albumArtist: "Same Artist", album: "Same Album", title: "Same Title", trackNumber: 1, trackTotal: 1),
            durationSeconds: 1,
            hasEmbeddedArtwork: false
        ))
        let enricher = MetadataEnricher(requestIntervalSeconds: 1.0, probe: probe, transport: transport)
        do {
            _ = try await enricher.enrich(job: ConversionJob(sourceURL: source, outputURL: directory.appendingPathComponent("ambiguous.mp3"))) { _ in }
            throw TestFailure.failed("Expected ambiguous MusicBrainz results to stop enrichment")
        } catch let FLAC2MP3Error.musicBrainzAmbiguous(_, candidates) {
            try require(candidates.count == 2, "Ambiguous MusicBrainz candidates were not preserved")
        }
        enricher.cleanup()
    }

    private static func testIgnoreMissingEnrichmentContinuesWithoutMetadataOrArtwork() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("unknown.flac")
        try Data().write(to: source)
        let transport = RecordingHTTPTransport { _ in
            HTTPResponse(statusCode: 200, headers: ["content-type": "application/json"], data: Data(#"{}"#.utf8))
        }
        let probe = FixedMetadataProbe(snapshot: AudioMetadataSnapshot(
            metadata: TrackMetadata(),
            durationSeconds: 1,
            hasEmbeddedArtwork: false
        ))
        let enricher = MetadataEnricher(requestIntervalSeconds: 1.0, probe: probe, transport: transport)
        let events = EventRecorder()
        let enriched = try await enricher.enrich(
            job: ConversionJob(sourceURL: source, outputURL: directory.appendingPathComponent("unknown.mp3")),
            onEvent: { event in events.record(event) },
            ignoreMissingEnrichment: true
        )
        enricher.cleanup()

        try require(enriched.metadata == nil, "Missing metadata should be omitted when ignore is enabled")
        try require(enriched.coverURL == nil, "Missing artwork should remain absent when ignore is enabled")
        try require(!enriched.copySourceMetadata, "Source metadata should not be copied when metadata is missing")
        let messages = events.logMessages
        try require(messages.contains { $0.contains("Missing metadata") }, "Missing metadata was not logged")
        try require(messages.contains { $0.contains("Missing cover artwork") }, "Missing cover artwork was not logged")
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
            "-metadata", "artist=Fixture Artist",
            "-metadata", "album=Fixture Album",
            "-metadata", "title=Fixture Title",
            "-metadata", "track=2/4",
            "-c:a", "flac", source.path
        ])
        try require(generated.status == 0, "Could not generate FLAC fixture: \(generated.standardError)")
        let probed = try await FFprobeMetadataProbe().probe(url: source)
        try require(probed.metadata.artist == "Fixture Artist", "ffprobe artist tag was not parsed")
        try require(probed.metadata.album == "Fixture Album", "ffprobe album tag was not parsed")
        try require(probed.metadata.title == "Fixture Title", "ffprobe title tag was not parsed")
        try require(probed.metadata.trackNumber == 2 && probed.metadata.trackTotal == 4, "ffprobe track position was not parsed")
        let originalSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber

        let plan = try LibraryScanner().scan(rootURL: directory, recursive: true)
        let summary = try await ConversionService().convert(plan: plan, quality: .v0VBR, enrichMetadata: false) { _ in }
        try require(summary.converted == 1 && summary.skipped == 0, "Unexpected conversion summary")
        let output = directory.appendingPathComponent("tone.mp3")
        try require(FileManager.default.fileExists(atPath: output.path), "MP3 output was not created")
        let convertedSize = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        try require((convertedSize?.intValue ?? 0) > 0, "MP3 output is empty")
        let convertedMetadata = try await FFprobeMetadataProbe().probe(url: output)
        try require(convertedMetadata.metadata.artist == "Fixture Artist", "Local artist metadata was not preserved when online enrichment was disabled")
        try require(convertedMetadata.metadata.title == "Fixture Title", "Local title metadata was not preserved when online enrichment was disabled")
        let finalSourceSize = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        try require(finalSourceSize?.intValue == originalSize?.intValue, "Source FLAC was modified")
    }

    private static func testConversionCanOmitSourceMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg: URL
        let ffprobe: URL
        do {
            ffmpeg = try await FFmpegLocator.locate()
            ffprobe = try await FFprobeLocator.locate()
        } catch {
            print("Skipping metadata omission integration test: \(error)")
            return
        }
        let source = directory.appendingPathComponent("tagged.flac")
        let generated = try await ProcessRunner().run(executable: ffmpeg, arguments: [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=1",
            "-metadata", "artist=Tagged Artist",
            "-metadata", "title=Tagged Title",
            "-c:a", "flac", source.path
        ])
        try require(generated.status == 0, "Could not generate metadata omission fixture: \(generated.standardError)")

        let output = directory.appendingPathComponent("tagged.mp3")
        let plan = ConversionPlan(jobs: [ConversionJob(
            sourceURL: source,
            outputURL: output,
            copySourceMetadata: false
        )])
        let summary = try await ConversionService().convert(plan: plan, quality: .v0VBR, enrichMetadata: false) { _ in }
        try require(summary.converted == 1, "Metadata omission fixture was not converted")

        let probed = try await ProcessRunner().run(executable: ffprobe, arguments: [
            "-hide_banner", "-loglevel", "error",
            "-show_entries", "format_tags=artist,title",
            "-of", "json", output.path
        ])
        try require(probed.status == 0, "Could not inspect metadata omission output: \(probed.standardError)")
        let object = try JSONSerialization.jsonObject(with: Data(probed.standardOutput.utf8)) as? [String: Any]
        let format = object?["format"] as? [String: Any]
        let tags = format?["tags"] as? [String: Any] ?? [:]
        try require(tags["artist"] == nil && tags["title"] == nil, "Source artist/title tags were copied despite the omission setting")
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
        let summary = try await ConversionService().convert(plan: plan, quality: .cbr320, enrichMetadata: false) { _ in }
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

private final class FixedMetadataProbe: AudioMetadataProbing, @unchecked Sendable {
    let snapshot: AudioMetadataSnapshot

    init(snapshot: AudioMetadataSnapshot) {
        self.snapshot = snapshot
    }

    func probe(url: URL) async throws -> AudioMetadataSnapshot {
        snapshot
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ event: ConversionEvent) {
        guard case let .log(message) = event else { return }
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var logMessages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private actor RecordingHTTPTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> HTTPResponse

    init(handler: @escaping @Sendable (URLRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }

    func requestCount() -> Int { requests.count }

    func firstUserAgent() -> String? { requests.first?.value(forHTTPHeaderField: "User-Agent") }

    func firstURL(containing fragment: String) -> URL? {
        requests.compactMap(\.url).first { $0.absoluteString.contains(fragment) }
    }
}
