import Foundation

struct AudioMetadataSnapshot: Sendable {
    let metadata: TrackMetadata
    let durationSeconds: Double?
    let hasEmbeddedArtwork: Bool
}

protocol AudioMetadataProbing: Sendable {
    func probe(url: URL) async throws -> AudioMetadataSnapshot
}

struct FFprobeMetadataProbe: AudioMetadataProbing {
    private let executable: URL?

    init(executable: URL? = nil) {
        self.executable = executable
    }

    func probe(url: URL) async throws -> AudioMetadataSnapshot {
        let ffprobe: URL
        if let executable {
            ffprobe = executable
        } else {
            ffprobe = try await FFprobeLocator.locate()
        }
        let result = try await ProcessRunner().run(executable: ffprobe, arguments: [
            "-hide_banner", "-loglevel", "error",
            "-show_entries", "format=duration:format_tags=artist,album_artist,album,title,date,genre,track,tracknumber,disc,discnumber,musicbrainz_trackid,musicbrainz_recordingid,musicbrainz_albumid,musicbrainz_releaseid,musicbrainz_releasegroupid,musicbrainz_artistid,musicbrainz_albumartistid,isrc",
            "-show_streams",
            "-of", "json",
            url.path
        ])
        guard result.status == 0 else {
            let details = result.standardError.isEmpty ? result.standardOutput : result.standardError
            throw FLAC2MP3Error.metadataProbeFailed(url, String(details.suffix(8_000)))
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        } catch {
            throw FLAC2MP3Error.metadataProbeFailed(url, "ffprobe returned invalid JSON: \(error.localizedDescription)")
        }
        guard let root = object as? [String: Any] else {
            throw FLAC2MP3Error.metadataProbeFailed(url, "ffprobe returned an unexpected JSON object")
        }

        let format = root["format"] as? [String: Any] ?? [:]
        let rawTags = format["tags"] as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        for (key, value) in rawTags {
            guard let string = stringValue(value) else { continue }
            tags[key.lowercased()] = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let trackPosition = splitPosition(firstTag(tags, keys: ["tracknumber", "track"]))
        let discPosition = splitPosition(firstTag(tags, keys: ["discnumber", "disc"]))
        let metadata = TrackMetadata(
            artist: firstTag(tags, keys: ["artist"]),
            albumArtist: firstTag(tags, keys: ["album_artist", "albumartist"]),
            album: firstTag(tags, keys: ["album"]),
            title: firstTag(tags, keys: ["title"]),
            date: firstTag(tags, keys: ["date", "year"]),
            genre: firstTag(tags, keys: ["genre"]),
            discNumber: discPosition.number.map(String.init),
            trackNumber: trackPosition.number,
            trackTotal: trackPosition.total,
            discTotal: discPosition.total,
            isrc: firstTag(tags, keys: ["isrc"]),
            musicBrainzRecordingID: firstTag(tags, keys: ["musicbrainz_recordingid", "musicbrainz_trackid"]),
            musicBrainzReleaseID: firstTag(tags, keys: ["musicbrainz_albumid", "musicbrainz_releaseid"]),
            musicBrainzReleaseGroupID: firstTag(tags, keys: ["musicbrainz_releasegroupid"]),
            musicBrainzArtistID: firstTag(tags, keys: ["musicbrainz_artistid"]),
            musicBrainzAlbumArtistID: firstTag(tags, keys: ["musicbrainz_albumartistid"])
        )

        let duration = doubleValue(format["duration"])
        let streams = root["streams"] as? [[String: Any]] ?? []
        let hasEmbeddedArtwork = streams.contains { stream in
            guard stringValue(stream["codec_type"])?.lowercased() == "video" else { return false }
            if let disposition = stream["disposition"] as? [String: Any], intValue(disposition["attached_pic"]) == 1 {
                return true
            }
            return intValue(stream["attached_pic"]) == 1
        }
        return AudioMetadataSnapshot(metadata: metadata, durationSeconds: duration, hasEmbeddedArtwork: hasEmbeddedArtwork)
    }
}

enum FFprobeLocator {
    static func locate() async throws -> URL {
        var candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/ffprobe" })
        }
        var uniqueCandidates: [String] = []
        for candidate in candidates where !uniqueCandidates.contains(candidate) { uniqueCandidates.append(candidate) }
        for candidate in uniqueCandidates {
            let url = URL(fileURLWithPath: candidate)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            if let result = try? await ProcessRunner().run(executable: url, arguments: ["-hide_banner", "-version"]), result.status == 0 {
                return url
            }
        }
        throw FLAC2MP3Error.ffprobeNotFound(uniqueCandidates)
    }
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

struct URLSessionHTTPTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, data: data)
    }
}

actor MusicBrainzRateLimiter {
    private let minimumIntervalNanoseconds: UInt64
    private var lastRequestStart: UInt64?

    init(intervalSeconds: Double) {
        let interval = max(0, min(60, intervalSeconds))
        minimumIntervalNanoseconds = UInt64(interval * 1_000_000_000)
    }

    func wait() async throws {
        try await wait(onWait: { _ in })
    }

    func wait(onWait: @escaping @Sendable (Double) -> Void) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        var waitNanoseconds: UInt64 = 0
        if let lastRequestStart {
            let target = lastRequestStart &+ minimumIntervalNanoseconds
            if now < target {
                waitNanoseconds = target - now
            }
        }

        if waitNanoseconds > 0 {
            onWait(Double(waitNanoseconds) / 1_000_000_000)
            try await Task.sleep(nanoseconds: waitNanoseconds)
        }

        // Record the instant immediately before the caller starts its request.
        // Conversion time is intentionally not part of this interval.
        lastRequestStart = DispatchTime.now().uptimeNanoseconds
    }
}

struct ReleaseSearchHit: Sendable {
    let id: String
    let title: String
    let artist: String?
    let date: String?
    let country: String?
    let score: Int
    let trackCount: Int?

    var candidate: MusicBrainzCandidate {
        MusicBrainzCandidate(id: id, title: title, artist: artist, date: date, country: country, score: score, trackCount: trackCount)
    }
}

struct ReleaseTrack: Sendable {
    let id: String?
    let title: String?
    let artist: String?
    let artistID: String?
    let isrc: String?
    let number: String?
    let discNumber: Int
    let trackTotal: Int
}

struct ReleaseDetails: Sendable {
    let id: String
    let title: String?
    let artist: String?
    let artistID: String?
    let date: String?
    let releaseGroupID: String?
    let genres: [String]
    let discTotal: Int
    let tracks: [ReleaseTrack]

    func track(for local: TrackMetadata) -> ReleaseTrack? {
        if let recordingID = local.musicBrainzRecordingID {
            let idMatches = tracks.filter { $0.id == recordingID }
            if idMatches.count == 1 { return idMatches[0] }
        }
        let positionMatches: [ReleaseTrack]
        if let trackNumber = local.trackNumber {
            positionMatches = tracks.filter { track in
                guard firstInteger(track.number) == trackNumber else { return false }
                if let discNumber = intValue(local.discNumber) { return track.discNumber == discNumber }
                return true
            }
            if positionMatches.count == 1 {
                let match = positionMatches[0]
                if local.title == nil ||
                    local.musicBrainzReleaseID != nil ||
                    normalized(match.title) == normalized(local.title) ||
                    local.trackTotal == match.trackTotal {
                    return match
                }
            }
        } else {
            positionMatches = []
        }

        let titleMatches = tracks.filter { track in
            guard normalized(track.title) == normalized(local.title) else { return false }
            guard let localArtist = local.artist, let trackArtist = track.artist else { return true }
            return normalized(localArtist) == normalized(trackArtist)
        }
        if titleMatches.count == 1 { return titleMatches[0] }
        if local.trackNumber == nil && tracks.count == 1 { return tracks[0] }
        return nil
    }

    func metadata(for local: TrackMetadata) -> TrackMetadata? {
        guard let track = track(for: local) else { return nil }
        return TrackMetadata(
            artist: track.artist ?? artist,
            albumArtist: artist,
            album: title,
            title: track.title,
            date: date,
            genre: genres.first,
            discNumber: track.discNumber > 0 ? String(track.discNumber) : nil,
            trackNumber: firstInteger(track.number),
            trackTotal: track.trackTotal > 0 ? track.trackTotal : nil,
            discTotal: discTotal > 0 ? discTotal : nil,
            isrc: track.isrc,
            musicBrainzRecordingID: track.id,
            musicBrainzReleaseID: id,
            musicBrainzReleaseGroupID: releaseGroupID,
            musicBrainzArtistID: track.artistID ?? artistID,
            musicBrainzAlbumArtistID: artistID
        )
    }
}

final class MusicBrainzClient: @unchecked Sendable {
    static let userAgent = "FLAC2MP3/1.0 (jose@cruset.com)"

    private let transport: any HTTPTransport
    private let limiter: MusicBrainzRateLimiter
    private var releaseCache: [String: ReleaseDetails] = [:]
    private var artworkCache: [String: URL] = [:]
    private var artworkMissing = Set<String>()
    private var temporaryDirectory: URL?
    private var temporaryArtwork: [URL] = []

    init(intervalSeconds: Double, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        limiter = MusicBrainzRateLimiter(intervalSeconds: max(1.0, min(60, intervalSeconds)))
        self.transport = transport
    }

    func resolve(
        local: TrackMetadata,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> ReleaseDetails? {
        if let releaseID = local.musicBrainzReleaseID, UUID(uuidString: releaseID) != nil {
            if let cached = releaseCache[releaseID] { return cached }
            guard let details = try await lookupRelease(id: releaseID, onWait: onWait) else { return nil }
            releaseCache[releaseID] = details
            return details
        }

        let query: String
        let hits: [ReleaseSearchHit]
        if let recordingID = local.musicBrainzRecordingID, UUID(uuidString: recordingID) != nil {
            query = "recording ID \(recordingID)"
            hits = try await lookupRecording(id: recordingID, onWait: onWait)
        } else if let album = local.album, !album.isEmpty {
            query = releaseQuery(local: local)
            hits = try await searchReleases(query: query, onWait: onWait)
        } else if let title = local.title, let artist = local.artist, !title.isEmpty, !artist.isEmpty {
            query = recordingQuery(title: title, artist: artist)
            hits = try await searchRecordings(query: query, local: local, onWait: onWait)
        } else {
            return nil
        }

        let eligible = hits.filter { isHighConfidence($0, local: local) }
        guard !eligible.isEmpty else { return nil }
        if eligible.count > 1 {
            throw FLAC2MP3Error.musicBrainzAmbiguous(query, eligible.prefix(8).map(\.candidate))
        }
        guard let details = try await lookupRelease(id: eligible[0].id, onWait: onWait) else { return nil }
        guard details.metadata(for: local) != nil else { return nil }
        releaseCache[details.id] = details
        return details
    }

    func artwork(
        for releaseID: String,
        releaseGroupID: String? = nil
    ) async throws -> URL? {
        if let cached = artworkCache[releaseID] { return cached }
        if !artworkMissing.contains(releaseID),
           let artwork = try await fetchArtwork(
               urlString: "https://coverartarchive.org/release/\(releaseID)/front-500",
               cacheKey: releaseID
           ) {
            return artwork
        }
        guard let releaseGroupID, UUID(uuidString: releaseGroupID) != nil else { return nil }
        let groupKey = "group:\(releaseGroupID)"
        if let cached = artworkCache[groupKey] { return cached }
        if artworkMissing.contains(groupKey) { return nil }
        guard let artwork = try await fetchArtwork(
            urlString: "https://coverartarchive.org/release-group/\(releaseGroupID)/front-500",
            cacheKey: groupKey
        ) else { return nil }
        artworkCache[releaseID] = artwork
        return artwork
    }

    private func fetchArtwork(
        urlString: String,
        cacheKey: String
    ) async throws -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        if let cached = artworkCache[cacheKey] { return cached }
        if artworkMissing.contains(cacheKey) { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/jpeg,image/png;q=0.9,image/*;q=0.8", forHTTPHeaderField: "Accept")

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw FLAC2MP3Error.coverArtRequestFailed(url, error.localizedDescription)
        }
        if response.statusCode == 404 {
            artworkMissing.insert(cacheKey)
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FLAC2MP3Error.coverArtHTTP(url, response.statusCode)
        }
        guard !response.data.isEmpty else {
            throw FLAC2MP3Error.coverArtDecode(url, "the response was empty")
        }
        let contentType = response.headers["content-type"]?.lowercased() ?? ""
        if !contentType.isEmpty && !contentType.contains("image/") {
            throw FLAC2MP3Error.coverArtDecode(url, "the response was not an image (\(contentType))")
        }
        let fileURL = try makeTemporaryArtworkURL()
        do {
            try response.data.write(to: fileURL, options: .atomic)
        } catch {
            throw FLAC2MP3Error.coverArtDecode(url, error.localizedDescription)
        }
        temporaryArtwork.append(fileURL)
        artworkCache[cacheKey] = fileURL
        return fileURL
    }

    func cleanup() {
        for file in temporaryArtwork { try? FileManager.default.removeItem(at: file) }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryArtwork.removeAll()
        temporaryDirectory = nil
    }

    private func searchReleases(
        query: String,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> [ReleaseSearchHit] {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components.url else { return [] }
        let root = try await musicBrainzJSON(url: url, onWait: onWait)
        let values = dictionaries(root["releases"] ?? root["release-list"])
        return values.compactMap(parseReleaseSearchHit)
    }

    private func searchRecordings(
        query: String,
        local: TrackMetadata,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> [ReleaseSearchHit] {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components.url else { return [] }
        let root = try await musicBrainzJSON(url: url, onWait: onWait)
        let recordings = dictionaries(root["recordings"] ?? root["recording-list"])
        var result: [ReleaseSearchHit] = []
        for recording in recordings {
            guard normalized(stringValue(recording["title"])) == normalized(local.title) else { continue }
            guard let score = intValue(recording["score"]), score >= 90 else { continue }
            let recordingArtist = artistCredit(recording["artist-credit"]).name
            let releases = dictionaries(recording["releases"] ?? recording["release-list"])
            result.append(contentsOf: releases.compactMap { value in
                guard let hit = parseReleaseSearchHit(value) else { return nil }
                return ReleaseSearchHit(
                    id: hit.id,
                    title: hit.title,
                    artist: hit.artist ?? recordingArtist,
                    date: hit.date,
                    country: hit.country,
                    score: max(hit.score, score),
                    trackCount: hit.trackCount
                )
            })
        }
        var unique: [String: ReleaseSearchHit] = [:]
        for hit in result { unique[hit.id] = hit }
        return Array(unique.values).sorted { $0.score > $1.score }
    }

    private func lookupRelease(
        id: String,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> ReleaseDetails? {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "inc", value: "recordings+artist-credits+release-groups+genres+isrcs"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components.url else { return nil }
        let response = try await musicBrainzResponse(url: url, onWait: onWait)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw FLAC2MP3Error.musicBrainzHTTP(url, response.statusCode, bodySnippet(response.data))
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw FLAC2MP3Error.musicBrainzDecode(url, "the response was not a JSON object")
            }
            return try parseReleaseDetails(root, url: url)
        } catch let error as FLAC2MP3Error {
            throw error
        } catch {
            throw FLAC2MP3Error.musicBrainzDecode(url, error.localizedDescription)
        }
    }

    private func lookupRecording(
        id: String,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> [ReleaseSearchHit] {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/\(id)") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "inc", value: "releases+artist-credits+isrcs"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        guard let url = components.url else { return [] }
        let response = try await musicBrainzResponse(url: url, onWait: onWait)
        if response.statusCode == 404 { return [] }
        guard (200..<300).contains(response.statusCode) else {
            throw FLAC2MP3Error.musicBrainzHTTP(url, response.statusCode, bodySnippet(response.data))
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw FLAC2MP3Error.musicBrainzDecode(url, "the response was not a JSON object")
            }
            let releases = dictionaries(root["releases"] ?? root["release-list"])
            return releases.compactMap { value in
                guard let hit = parseReleaseSearchHit(value) else { return nil }
                return ReleaseSearchHit(id: hit.id, title: hit.title, artist: hit.artist, date: hit.date, country: hit.country, score: max(100, hit.score), trackCount: hit.trackCount)
            }
        } catch let error as FLAC2MP3Error {
            throw error
        } catch {
            throw FLAC2MP3Error.musicBrainzDecode(url, error.localizedDescription)
        }
    }

    private func musicBrainzJSON(
        url: URL,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> [String: Any] {
        let response = try await musicBrainzResponse(url: url, onWait: onWait)
        guard (200..<300).contains(response.statusCode) else {
            throw FLAC2MP3Error.musicBrainzHTTP(url, response.statusCode, bodySnippet(response.data))
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw FLAC2MP3Error.musicBrainzDecode(url, "the response was not a JSON object")
            }
            return root
        } catch let error as FLAC2MP3Error {
            throw error
        } catch {
            throw FLAC2MP3Error.musicBrainzDecode(url, error.localizedDescription)
        }
    }

    private func musicBrainzResponse(
        url: URL,
        onWait: @escaping @Sendable (Double) -> Void
    ) async throws -> HTTPResponse {
        try await limiter.wait(onWait: onWait)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            return try await transport.send(request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw FLAC2MP3Error.musicBrainzRequestFailed(url, error.localizedDescription)
        }
    }

    private func releaseQuery(local: TrackMetadata) -> String {
        var terms = ["release:\"\(luceneEscape(local.album ?? ""))\""]
        if let artist = local.albumArtist ?? local.artist, !artist.isEmpty {
            terms.append("artist:\"\(luceneEscape(artist))\"")
        }
        return terms.joined(separator: " AND ")
    }

    private func recordingQuery(title: String, artist: String) -> String {
        "recording:\"\(luceneEscape(title))\" AND artist:\"\(luceneEscape(artist))\""
    }

    private func isHighConfidence(_ hit: ReleaseSearchHit, local: TrackMetadata) -> Bool {
        guard hit.score >= 90 else { return false }
        if let album = local.album, !album.isEmpty {
            guard normalized(hit.title) == normalized(album) else { return false }
        }
        if let localArtist = local.albumArtist ?? local.artist, !localArtist.isEmpty {
            guard artistMatches(localArtist, hit.artist) else { return false }
        }
        if let localYear = year(local.date), let candidateYear = year(hit.date), localYear != candidateYear {
            return false
        }
        if let localTrackTotal = local.trackTotal, let candidateTrackCount = hit.trackCount, localTrackTotal != candidateTrackCount {
            return false
        }
        return true
    }

    private func parseReleaseSearchHit(_ value: [String: Any]) -> ReleaseSearchHit? {
        guard let id = stringValue(value["id"]), let title = stringValue(value["title"]) else { return nil }
        let credit = artistCredit(value["artist-credit"])
        let artist = credit.name ?? stringValue(value["artist-credit-phrase"]) ?? stringValue(value["artist"])
        let score = intValue(value["score"]) ?? 0
        let trackCount = intValue(value["track-count"]) ?? mediaTrackCount(value["media"])
        return ReleaseSearchHit(
            id: id,
            title: title,
            artist: artist,
            date: stringValue(value["date"]),
            country: stringValue(value["country"]),
            score: score,
            trackCount: trackCount
        )
    }

    private func parseReleaseDetails(_ value: [String: Any], url: URL) throws -> ReleaseDetails {
        guard let id = stringValue(value["id"]) else {
            throw FLAC2MP3Error.musicBrainzDecode(url, "the release has no ID")
        }
        let credit = artistCredit(value["artist-credit"])
        let releaseGroup = value["release-group"] as? [String: Any]
        let media = dictionaries(value["media"])
        let discTotal = media.count
        var tracks: [ReleaseTrack] = []
        for (mediaIndex, medium) in media.enumerated() {
            let discNumber = intValue(medium["position"]) ?? (mediaIndex + 1)
            let mediumTracks = dictionaries(medium["tracks"] ?? medium["track-list"])
            let trackTotal = intValue(medium["track-count"]) ?? mediumTracks.count
            for track in mediumTracks {
                let recording = track["recording"] as? [String: Any]
                let trackCredit = artistCredit(track["artist-credit"] ?? recording?["artist-credit"])
                let trackArtist = trackCredit.name ?? stringValue(recording?["artist-credit-phrase"])
                let isrcs = strings(recording?["isrcs"])
                tracks.append(ReleaseTrack(
                    id: stringValue(recording?["id"]) ?? stringValue(track["id"]),
                    title: stringValue(track["title"]) ?? stringValue(recording?["title"]),
                    artist: trackArtist,
                    artistID: trackCredit.ids.first,
                    isrc: isrcs.first,
                    number: stringValue(track["number"]) ?? stringValue(track["position"]),
                    discNumber: discNumber,
                    trackTotal: trackTotal
                ))
            }
        }
        let genres = dictionaries(value["genres"]).compactMap { stringValue($0["name"]) }
        return ReleaseDetails(
            id: id,
            title: stringValue(value["title"]),
            artist: credit.name ?? stringValue(value["artist-credit-phrase"]),
            artistID: credit.ids.first,
            date: stringValue(value["date"]),
            releaseGroupID: stringValue(releaseGroup?["id"]),
            genres: genres,
            discTotal: discTotal,
            tracks: tracks
        )
    }

    private func makeTemporaryArtworkURL() throws -> URL {
        if temporaryDirectory == nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FLAC2MP3-Artwork-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory
        }
        return temporaryDirectory!.appendingPathComponent("art-\(UUID().uuidString).jpg")
    }
}

final class MetadataEnricher: @unchecked Sendable {
    private enum Resolution: Sendable {
        case release(ReleaseDetails)
        case noMatch
    }

    private let probe: any AudioMetadataProbing
    private let client: MusicBrainzClient
    private var probeCache: [String: AudioMetadataSnapshot] = [:]
    private var resolutionCache: [String: Resolution] = [:]

    init(
        requestIntervalSeconds: Double,
        probe: any AudioMetadataProbing = FFprobeMetadataProbe(),
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.probe = probe
        client = MusicBrainzClient(intervalSeconds: requestIntervalSeconds, transport: transport)
    }

    func enrich(
        job: ConversionJob,
        onEvent: @escaping @Sendable (ConversionEvent) -> Void,
        useCoverJPG: Bool = false,
        ignoreMissingEnrichment: Bool = false
    ) async throws -> ConversionJob {
        let sourceKey = job.sourceURL.standardizedFileURL.path.lowercased()
        let snapshot: AudioMetadataSnapshot
        if let cached = probeCache[sourceKey] {
            snapshot = cached
        } else {
            snapshot = try await probe.probe(url: job.sourceURL)
            probeCache[sourceKey] = snapshot
        }

        let sourceMetadata = (job.metadata?.merged(over: snapshot.metadata)) ?? snapshot.metadata
        let local = inferredMetadata(for: job.sourceURL, base: sourceMetadata)
        let resolutionKey = makeResolutionKey(local: local, sourceURL: job.sourceURL)
        onEvent(.metadataLookup(path: job.sourceURL.path))

        let resolution: Resolution
        if let cached = resolutionCache[resolutionKey] {
            resolution = cached
            onEvent(.log("Reusing MusicBrainz release context for \(job.sourceURL.lastPathComponent)."))
        } else {
            let resolved = try await client.resolve(
                local: local,
                onWait: { seconds in onEvent(.waiting(seconds: seconds)) }
            )
            resolution = resolved.map(Resolution.release) ?? .noMatch
            resolutionCache[resolutionKey] = resolution
            if resolved == nil {
                onEvent(.log("No unique MusicBrainz match for \(job.sourceURL.lastPathComponent); using local metadata/artwork."))
            }
        }

        var metadata = local
        var coverURL = job.coverURL
        switch resolution {
        case let .release(details):
            if let onlineMetadata = details.metadata(for: local) {
                metadata = onlineMetadata.merged(over: local)
                onEvent(.log("Using MusicBrainz release \(details.id) for \(job.sourceURL.lastPathComponent)."))
                if useCoverJPG, coverURL != nil {
                    onEvent(.log("Using local cover.jpg for \(job.sourceURL.lastPathComponent); skipping Cover Art Archive lookup."))
                } else {
                    onEvent(.artworkLookup(path: details.id))
                    if let artwork = try await client.artwork(for: details.id, releaseGroupID: details.releaseGroupID) {
                        coverURL = artwork
                        onEvent(.log("Using Cover Art Archive front artwork for release \(details.id)."))
                    } else {
                        onEvent(.log("No Cover Art Archive front image for release \(details.id); using local artwork if available."))
                    }
                }
            } else {
                onEvent(.log("MusicBrainz release \(details.id) did not contain a matching track; using local metadata/artwork."))
            }
        case .noMatch:
            break
        }

        let metadataAvailable = nonEmpty(metadata.title) && nonEmpty(metadata.artist)
        if !metadataAvailable {
            guard ignoreMissingEnrichment else {
                throw FLAC2MP3Error.missingMetadata(job.sourceURL)
            }
            onEvent(.log("Missing metadata for \(job.sourceURL.lastPathComponent); continuing without metadata."))
        }

        let artworkAvailable = coverURL != nil || snapshot.hasEmbeddedArtwork
        if !artworkAvailable {
            guard ignoreMissingEnrichment else {
                throw FLAC2MP3Error.missingArtwork(job.sourceURL)
            }
            onEvent(.log("Missing cover artwork for \(job.sourceURL.lastPathComponent); continuing without cover art."))
        }

        return ConversionJob(
            id: job.id,
            sourceURL: job.sourceURL,
            outputURL: job.outputURL,
            metadata: metadataAvailable ? metadata : nil,
            startSeconds: job.startSeconds,
            endSeconds: job.endSeconds,
            coverURL: coverURL,
            copySourceMetadata: metadataAvailable
        )
    }

    func cleanup() {
        client.cleanup()
    }

    private func makeResolutionKey(local: TrackMetadata, sourceURL: URL) -> String {
        let album = normalized(local.album) ?? ""
        let albumArtist = normalized(local.albumArtist ?? local.artist) ?? ""
        let date = year(local.date) ?? ""
        let trackTotal = local.trackTotal.map(String.init) ?? ""
        let title = album.isEmpty ? normalized(local.title) ?? "" : ""
        return [sourceURL.deletingLastPathComponent().standardizedFileURL.path.lowercased(), album, albumArtist, date, trackTotal, title].joined(separator: "|")
    }
}

private func inferredMetadata(for sourceURL: URL, base: TrackMetadata) -> TrackMetadata {
    let stem = sourceURL.deletingPathExtension().lastPathComponent
    let parts = stem.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    var trackNumber = base.trackNumber
    var artist = base.artist
    var title = base.title
    if parts.count >= 3, let number = Int(parts[0]) {
        trackNumber = trackNumber ?? number
        artist = artist ?? parts[1]
        title = title ?? parts.dropFirst(2).joined(separator: " - ")
    } else if parts.count == 2 {
        artist = artist ?? parts[0]
        title = title ?? parts[1]
    }

    var album = base.album
    var albumArtist = base.albumArtist
    if let parent = sourceURL.deletingLastPathComponent().lastPathComponent.nonEmpty {
        if albumArtist == nil {
            let parentParts = parent.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if parentParts.count >= 3, parentParts[1].count == 4, Int(parentParts[1]) != nil {
                albumArtist = parentParts[0]
                album = album ?? parentParts.dropFirst(2).joined(separator: " - ")
            }
        }
        album = album ?? parent
    }
    return TrackMetadata(
        artist: artist,
        albumArtist: albumArtist,
        album: album,
        title: title,
        date: base.date,
        genre: base.genre,
        discNumber: base.discNumber,
        trackNumber: trackNumber,
        trackTotal: base.trackTotal,
        discTotal: base.discTotal,
        isrc: base.isrc,
        musicBrainzRecordingID: base.musicBrainzRecordingID,
        musicBrainzReleaseID: base.musicBrainzReleaseID,
        musicBrainzReleaseGroupID: base.musicBrainzReleaseGroupID,
        musicBrainzArtistID: base.musicBrainzArtistID,
        musicBrainzAlbumArtistID: base.musicBrainzAlbumArtistID
    )
}

private func firstTag(_ tags: [String: String], keys: [String]) -> String? {
    for key in keys {
        if let value = tags[key], !value.isEmpty { return value }
    }
    return nil
}

private func splitPosition(_ value: String?) -> (number: Int?, total: Int?) {
    guard let value, !value.isEmpty else { return (nil, nil) }
    let pieces = value.split(separator: "/", maxSplits: 1).map(String.init)
    return (firstInteger(pieces.first), pieces.count > 1 ? firstInteger(pieces[1]) : nil)
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? firstInteger(value) }
    return nil
}

private func doubleValue(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func firstInteger(_ value: String?) -> Int? {
    guard let value else { return nil }
    let digits = value.drop(while: { !$0.isNumber }).prefix { $0.isNumber }
    return Int(digits)
}

private func intValue(_ value: String?) -> Int? {
    firstInteger(value)
}

private func dictionaries(_ value: Any?) -> [[String: Any]] {
    if let values = value as? [[String: Any]] { return values }
    if let values = value as? [Any] { return values.compactMap { $0 as? [String: Any] } }
    return []
}

private func strings(_ value: Any?) -> [String] {
    if let values = value as? [String] { return values }
    if let values = value as? [Any] { return values.compactMap(stringValue) }
    return []
}

private func artistCredit(_ value: Any?) -> (name: String?, ids: [String]) {
    let parts = dictionaries(value)
    guard !parts.isEmpty else { return (nil, []) }
    var name = ""
    var ids: [String] = []
    for part in parts {
        let partName = stringValue(part["name"]) ?? stringValue((part["artist"] as? [String: Any])?["name"]) ?? ""
        name += partName
        name += stringValue(part["joinphrase"]) ?? ""
        if let id = stringValue((part["artist"] as? [String: Any])?["id"]) { ids.append(id) }
    }
    return (name.isEmpty ? nil : name, ids)
}

private func mediaTrackCount(_ value: Any?) -> Int? {
    let media = dictionaries(value)
    let counts = media.compactMap { intValue($0["track-count"]) }
    guard !counts.isEmpty else { return nil }
    return counts.reduce(0, +)
}

private func normalized(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
    let result = String(String.UnicodeScalarView(scalars))
    return result.isEmpty ? nil : result
}

private func artistMatches(_ local: String, _ candidate: String?) -> Bool {
    guard let candidate else { return false }
    if normalized(local) == normalized(candidate) { return true }
    let aliases = Set(["va", "various", "variousartist", "variousartists"])
    return aliases.contains(normalized(local) ?? "") && aliases.contains(normalized(candidate) ?? "")
}

private func year(_ value: String?) -> String? {
    guard let value else { return nil }
    return String(value.prefix(4)).count == 4 && value.prefix(4).allSatisfy(\.isNumber) ? String(value.prefix(4)) : nil
}

private func nonEmpty(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private func luceneEscape(_ value: String) -> String {
    let special = CharacterSet(charactersIn: "+-!(){}[]^\"~*?:\\/")
    return value.unicodeScalars.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
}

private func bodySnippet(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).suffix(2_000).description
}
