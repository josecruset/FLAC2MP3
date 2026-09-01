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
    let requestIntervalSeconds: Double
    let useMusicBrainz: Bool
    let useCoverJPG: Bool
    let ignoreMissingEnrichment: Bool
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
    var discTotal: Int?
    var isrc: String?
    var musicBrainzRecordingID: String?
    var musicBrainzReleaseID: String?
    var musicBrainzReleaseGroupID: String?
    var musicBrainzArtistID: String?
    var musicBrainzAlbumArtistID: String?

    init(
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        title: String? = nil,
        date: String? = nil,
        genre: String? = nil,
        discNumber: String? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discTotal: Int? = nil,
        isrc: String? = nil,
        musicBrainzRecordingID: String? = nil,
        musicBrainzReleaseID: String? = nil,
        musicBrainzReleaseGroupID: String? = nil,
        musicBrainzArtistID: String? = nil,
        musicBrainzAlbumArtistID: String? = nil
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
        self.discTotal = discTotal
        self.isrc = isrc
        self.musicBrainzRecordingID = musicBrainzRecordingID
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.musicBrainzReleaseGroupID = musicBrainzReleaseGroupID
        self.musicBrainzArtistID = musicBrainzArtistID
        self.musicBrainzAlbumArtistID = musicBrainzAlbumArtistID
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
            trackTotal: trackTotal ?? base.trackTotal,
            discTotal: discTotal ?? base.discTotal,
            isrc: isrc ?? base.isrc,
            musicBrainzRecordingID: musicBrainzRecordingID ?? base.musicBrainzRecordingID,
            musicBrainzReleaseID: musicBrainzReleaseID ?? base.musicBrainzReleaseID,
            musicBrainzReleaseGroupID: musicBrainzReleaseGroupID ?? base.musicBrainzReleaseGroupID,
            musicBrainzArtistID: musicBrainzArtistID ?? base.musicBrainzArtistID,
            musicBrainzAlbumArtistID: musicBrainzAlbumArtistID ?? base.musicBrainzAlbumArtistID
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
    /// Whether FFmpeg should copy tags from the source when no explicit metadata is available.
    /// This is disabled for jobs where the user opted to continue without metadata.
    let copySourceMetadata: Bool

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        outputURL: URL,
        metadata: TrackMetadata? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        coverURL: URL? = nil,
        copySourceMetadata: Bool = true
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.metadata = metadata
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.coverURL = coverURL
        self.copySourceMetadata = copySourceMetadata
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

struct MusicBrainzCandidate: Equatable, Sendable {
    let id: String
    let title: String
    let artist: String?
    let date: String?
    let country: String?
    let score: Int
    let trackCount: Int?

    var webURL: URL {
        URL(string: "https://musicbrainz.org/release/\(id)")!
    }
}

enum ConversionEvent: Sendable {
    case scanning(path: String, discovered: Int)
    case planReady(total: Int, skipped: Int)
    case waiting(seconds: Double)
    case metadataLookup(path: String)
    case artworkLookup(path: String)
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
    case invalidRequestInterval(Double)
    case ffprobeNotFound([String])
    case metadataProbeFailed(URL, String)
    case musicBrainzRequestFailed(URL, String)
    case musicBrainzHTTP(URL, Int, String)
    case musicBrainzDecode(URL, String)
    case musicBrainzAmbiguous(String, [MusicBrainzCandidate])
    case missingMetadata(URL)
    case coverArtHTTP(URL, Int)
    case coverArtRequestFailed(URL, String)
    case coverArtDecode(URL, String)
    case missingArtwork(URL)

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
        case let .invalidRequestInterval(value):
            return "The wait between MusicBrainz requests must be between 1.0 and 60.0 seconds (received \(value))."
        case let .ffprobeNotFound(candidates):
            return "ffprobe was not found. Checked: \(candidates.joined(separator: ", ")). Install it with Homebrew (`brew install ffmpeg`) and try again."
        case let .metadataProbeFailed(url, reason):
            return "Could not read FLAC metadata from \(url.lastPathComponent): \(reason)"
        case let .musicBrainzRequestFailed(url, reason):
            return "Could not contact MusicBrainz at \(url.absoluteString): \(reason)"
        case let .musicBrainzHTTP(url, status, details):
            let suffix = details.isEmpty ? "" : "\n\n\(details)"
            return "MusicBrainz request failed (HTTP \(status)): \(url.absoluteString).\(suffix)"
        case let .musicBrainzDecode(url, reason):
            return "MusicBrainz returned invalid data for \(url.absoluteString): \(reason)"
        case let .musicBrainzAmbiguous(query, candidates):
            let details = candidates.map { candidate in
                let artist = candidate.artist.map { " — \($0)" } ?? ""
                let date = candidate.date.map { " (\($0))" } ?? ""
                return "• \(candidate.title)\(artist)\(date), score \(candidate.score): \(candidate.webURL.absoluteString)"
            }.joined(separator: "\n")
            return "MusicBrainz returned multiple plausible releases for \(query). Choose one or refine the local tags.\n\n\(details)"
        case let .missingMetadata(url):
            return "MusicBrainz and the local file did not provide the required title and artist for \(url.lastPathComponent)."
        case let .coverArtHTTP(url, status):
            return "Cover Art Archive request failed (HTTP \(status)): \(url.absoluteString)"
        case let .coverArtRequestFailed(url, reason):
            return "Could not contact the Cover Art Archive at \(url.absoluteString): \(reason)"
        case let .coverArtDecode(url, reason):
            return "Cover Art Archive returned unusable artwork for \(url.absoluteString): \(reason)"
        case let .missingArtwork(url):
            return "No MusicBrainz or local cover artwork is available for \(url.lastPathComponent)."
        }
    }
}
