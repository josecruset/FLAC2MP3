import Foundation

enum MP3Quality: String, CaseIterable, Identifiable, Sendable {
    case v0VBR = "LAME V0 VBR"
    case cbr320 = "320 kbps CBR"

    var id: String { rawValue }
}

struct ConversionSettings: Sendable {
    let rootURL: URL
    let recursive: Bool
    let quality: MP3Quality
}

struct TrackMetadata: Equatable, Sendable {
    var artist: String?
    var albumArtist: String?
    var album: String?
    var title: String?
    var date: String?
    var genre: String?
    var discNumber: String?
    var trackNumber: Int?
    var trackTotal: Int?

    init(
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        title: String? = nil,
        date: String? = nil,
        genre: String? = nil,
        discNumber: String? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil
    ) {
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.title = title
        self.date = date
        self.genre = genre
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
    }

    func merged(over base: TrackMetadata) -> TrackMetadata {
        TrackMetadata(
            artist: artist ?? base.artist,
            albumArtist: albumArtist ?? base.albumArtist,
            album: album ?? base.album,
            title: title ?? base.title,
            date: date ?? base.date,
            genre: genre ?? base.genre,
            discNumber: discNumber ?? base.discNumber,
            trackNumber: trackNumber ?? base.trackNumber,
            trackTotal: trackTotal ?? base.trackTotal
        )
    }
}

struct ConversionJob: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let outputURL: URL
    let metadata: TrackMetadata?
    let startSeconds: Double?
    let endSeconds: Double?
    let coverURL: URL?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        outputURL: URL,
        metadata: TrackMetadata? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        coverURL: URL? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.metadata = metadata
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.coverURL = coverURL
    }

    var isSegment: Bool {
        startSeconds != nil || endSeconds != nil || metadata?.trackNumber != nil
    }
}

struct ConversionPlan: Sendable {
    let jobs: [ConversionJob]
}

struct ConversionSummary: Sendable {
    let converted: Int
    let skipped: Int
    let total: Int
}

enum ConversionEvent: Sendable {
    case scanning(path: String, discovered: Int)
    case planReady(total: Int, skipped: Int)
    case started(index: Int, total: Int, job: ConversionJob)
    case progress(index: Int, total: Int, fraction: Double?)
    case converted(index: Int, total: Int, job: ConversionJob)
    case skipped(index: Int, total: Int, job: ConversionJob)
    case log(String)
}

enum FLAC2MP3Error: LocalizedError, Equatable {
    case rootIsNotDirectory(URL)
    case unableToRead(URL, String)
    case malformedCue(URL, String)
    case ambiguousCue(URL, [URL])
    case cueReferencesMissingFile(URL, String)
    case noAudioStream(URL)
    case ffmpegNotFound([String])
    case ffmpegMissingLame(URL)
    case commandFailed(URL, Int32, String)
    case outputConflict(URL)
    case outputMoveFailed(URL, URL, String)

    var errorDescription: String? {
        switch self {
        case let .rootIsNotDirectory(url):
            return "The selected folder is not a directory: \(url.path)"
        case let .unableToRead(url, reason):
            return "Could not read \(url.path): \(reason)"
        case let .malformedCue(url, reason):
            return "Malformed CUE sheet \(url.lastPathComponent): \(reason)"
        case let .ambiguousCue(flac, cues):
            let names = cues.map(\.lastPathComponent).joined(separator: ", ")
            return "More than one CUE sheet matches \(flac.lastPathComponent): \(names)"
        case let .cueReferencesMissingFile(cue, file):
            return "CUE sheet \(cue.lastPathComponent) references a missing FLAC: \(file)"
        case let .noAudioStream(url):
            return "No audio stream was found in \(url.lastPathComponent)."
        case let .ffmpegNotFound(candidates):
            return "FFmpeg was not found. Checked: \(candidates.joined(separator: ", ")). Install it with Homebrew (`brew install ffmpeg`) and try again."
        case let .ffmpegMissingLame(url):
            return "FFmpeg at \(url.path) does not provide the libmp3lame encoder. Install a full Homebrew FFmpeg build and try again."
        case let .commandFailed(url, code, details):
            let suffix = details.isEmpty ? "" : "\n\n\(details)"
            return "FFmpeg failed for \(url.lastPathComponent) (exit code \(code)).\(suffix)"
        case let .outputConflict(url):
            return "Two conversion jobs would write the same output: \(url.path)"
        case let .outputMoveFailed(source, destination, reason):
            return "Could not finalize \(source.lastPathComponent) as \(destination.lastPathComponent): \(reason)"
        }
    }
}
