import Foundation

struct ConversionService {
    func convert(
        plan: ConversionPlan,
        quality: MP3Quality,
        requestIntervalSeconds: Double = 1.0,
        enrichMetadata: Bool = true,
        ignoreMissingEnrichment: Bool = false,
        onEvent: @escaping @Sendable (ConversionEvent) -> Void
    ) async throws -> ConversionSummary {
        guard requestIntervalSeconds >= 1.0, requestIntervalSeconds <= 60.0 else {
            throw FLAC2MP3Error.invalidRequestInterval(requestIntervalSeconds)
        }
        let ffmpeg = try await FFmpegLocator.locate()
        let runner = ProcessRunner()
        let enricher = enrichMetadata ? MetadataEnricher(requestIntervalSeconds: requestIntervalSeconds) : nil
        defer { enricher?.cleanup() }
        let total = plan.jobs.count
        let initialSkipped = plan.jobs.reduce(into: 0) { count, job in
            if FileManager.default.fileExists(atPath: job.outputURL.path) { count += 1 }
        }
        onEvent(.planReady(total: total, skipped: initialSkipped))

        var converted = 0
        var skipped = 0
        var processedMissingOutputs = 0
        for (offset, originalJob) in plan.jobs.enumerated() {
            try Task.checkCancellation()
            let index = offset + 1
            if FileManager.default.fileExists(atPath: originalJob.outputURL.path) {
                skipped += 1
                onEvent(.skipped(index: index, total: total, job: originalJob))
                continue
            }

            if enrichMetadata && processedMissingOutputs > 0 {
                onEvent(.waiting(seconds: requestIntervalSeconds))
                try await Task.sleep(nanoseconds: UInt64(requestIntervalSeconds * 1_000_000_000))
            }

            let job: ConversionJob
            if let enricher {
                job = try await enricher.enrich(
                    job: originalJob,
                    onEvent: onEvent,
                    ignoreMissingEnrichment: ignoreMissingEnrichment
                )
            } else {
                job = originalJob
            }
            try Task.checkCancellation()
            processedMissingOutputs += 1
            onEvent(.started(index: index, total: total, job: job))
            let temporaryURL = temporaryOutputURL(for: job.outputURL)
            defer {
                if FileManager.default.fileExists(atPath: temporaryURL.path) {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            }

            let arguments = makeArguments(job: job, quality: quality, temporaryURL: temporaryURL)
            let expectedDuration = job.endSeconds.flatMap { end in
                job.startSeconds.map { max(0, end - $0) }
            }
            let result = try await runner.run(executable: ffmpeg, arguments: arguments) { elapsed in
                let fraction: Double?
                if elapsed == Double.greatestFiniteMagnitude {
                    fraction = 1
                } else if let expectedDuration, expectedDuration > 0 {
                    fraction = min(1, max(0, elapsed / expectedDuration))
                } else {
                    fraction = nil
                }
                onEvent(.progress(index: index, total: total, fraction: fraction))
            }
            try Task.checkCancellation()
            guard result.status == 0 else {
                let details = result.standardError.isEmpty ? result.standardOutput : result.standardError
                throw FLAC2MP3Error.commandFailed(job.sourceURL, result.status, String(details.suffix(8_000)))
            }
            guard FileManager.default.fileExists(atPath: temporaryURL.path) else {
                throw FLAC2MP3Error.commandFailed(job.sourceURL, result.status, "FFmpeg exited successfully but did not create an output file.")
            }

            if FileManager.default.fileExists(atPath: job.outputURL.path) {
                skipped += 1
                onEvent(.skipped(index: index, total: total, job: job))
                continue
            }
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: job.outputURL)
            } catch {
                throw FLAC2MP3Error.outputMoveFailed(temporaryURL, job.outputURL, error.localizedDescription)
            }
            converted += 1
            onEvent(.converted(index: index, total: total, job: job))
        }
        return ConversionSummary(converted: converted, skipped: skipped, total: total)
    }

    private func makeArguments(job: ConversionJob, quality: MP3Quality, temporaryURL: URL) -> [String] {
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", job.sourceURL.path]
        if let coverURL = job.coverURL {
            arguments += ["-i", coverURL.path]
        }
        if let start = job.startSeconds, start > 0 {
            arguments += ["-ss", formatSeconds(start)]
        }
        if let start = job.startSeconds, let end = job.endSeconds, end > start {
            arguments += ["-t", formatSeconds(end - start)]
        }

        arguments += ["-map", "0:a:0"]
        arguments += job.copySourceMetadata ? ["-map_metadata", "0"] : ["-map_metadata", "-1"]
        if job.coverURL != nil {
            arguments += ["-map", "1:v:0", "-c:v", "mjpeg", "-disposition:v", "attached_pic", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)"]
        } else {
            arguments += ["-map", "0:v:0?", "-c:v", "copy", "-disposition:v", "attached_pic"]
        }

        arguments += ["-c:a", "libmp3lame"]
        switch quality {
        case .v0VBR:
            arguments += ["-q:a", "0"]
        case .cbr320:
            arguments += ["-b:a", "320k"]
        }
        arguments += ["-id3v2_version", "3", "-write_id3v1", "1"]
        if let metadata = job.metadata {
            arguments += metadataArguments(metadata)
        }
        arguments += ["-progress", "pipe:1", temporaryURL.path]
        return arguments
    }

    private func metadataArguments(_ metadata: TrackMetadata) -> [String] {
        var arguments: [String] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            arguments += ["-metadata", "\(key)=\(value)"]
        }
        add("artist", metadata.artist)
        add("album_artist", metadata.albumArtist)
        add("album", metadata.album)
        add("title", metadata.title)
        add("date", metadata.date)
        add("genre", metadata.genre)
        if let trackNumber = metadata.trackNumber {
            let value = metadata.trackTotal.map { "\(trackNumber)/\($0)" } ?? String(trackNumber)
            add("track", value)
        }
        if let discNumber = metadata.discNumber {
            let value = metadata.discTotal.map { "\(discNumber)/\($0)" } ?? discNumber
            add("disc", value)
        }
        add("isrc", metadata.isrc)
        add("musicbrainz_recordingid", metadata.musicBrainzRecordingID)
        add("musicbrainz_trackid", metadata.musicBrainzRecordingID)
        add("musicbrainz_albumid", metadata.musicBrainzReleaseID)
        add("musicbrainz_releaseid", metadata.musicBrainzReleaseID)
        add("musicbrainz_releasegroupid", metadata.musicBrainzReleaseGroupID)
        add("musicbrainz_artistid", metadata.musicBrainzArtistID)
        add("musicbrainz_albumartistid", metadata.musicBrainzAlbumArtistID)
        return arguments
    }

    private func temporaryOutputURL(for outputURL: URL) -> URL {
        let token = UUID().uuidString.lowercased()
        return outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).\(token).tmp.mp3")
    }

    private func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}
