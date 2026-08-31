import Foundation

struct CueTrack: Sendable {
    let number: Int
    let sourceURL: URL
    let startSeconds: Double
    let endSeconds: Double?
    let metadata: TrackMetadata
}

struct CueDocument: Sendable {
    let url: URL
    let albumMetadata: TrackMetadata
    let tracks: [CueTrack]

    var referencedFLACURLs: [URL] {
        var seen = Set<String>()
        return tracks.compactMap { track in
            guard track.sourceURL.pathExtension.lowercased() == "flac" else { return nil }
            let key = track.sourceURL.standardizedFileURL.path.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return track.sourceURL
        }
    }
}

enum CueParser {
    static func parse(url: URL) throws -> CueDocument {
        let text = try readText(url: url)
        let lines = text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines)

        var albumPerformer: String?
        var albumTitle: String?
        var albumDate: String?
        var albumGenre: String?
        var currentFileURL: URL?
        var workingTracks: [WorkingTrack] = []
        var currentTrack: WorkingTrack?

        func finishCurrentTrack() throws {
            guard let currentTrack else { return }
            guard currentTrack.index01 != nil else {
                throw FLAC2MP3Error.malformedCue(url, "Track \(currentTrack.number) has no INDEX 01 entry.")
            }
            workingTracks.append(currentTrack)
        }

        for (lineNumber, rawLine) in lines.enumerated() {
            let tokens = tokenize(rawLine)
            guard let command = tokens.first?.uppercased() else { continue }

            switch command {
            case "FILE":
                guard tokens.count >= 2 else {
                    throw FLAC2MP3Error.malformedCue(url, "FILE on line \(lineNumber + 1) has no path.")
                }
                let filePath = tokens[1]
                let base = url.deletingLastPathComponent()
                currentFileURL = URL(fileURLWithPath: filePath, relativeTo: base).standardizedFileURL
            case "TRACK":
                try finishCurrentTrack()
                guard tokens.count >= 2, let number = Int(tokens[1]) else {
                    throw FLAC2MP3Error.malformedCue(url, "Invalid TRACK declaration on line \(lineNumber + 1).")
                }
                guard let currentFileURL else {
                    throw FLAC2MP3Error.malformedCue(url, "TRACK \(number) appears before a FILE declaration.")
                }
                currentTrack = WorkingTrack(number: number, sourceURL: currentFileURL)
            case "INDEX":
                guard tokens.count >= 3, let index = Int(tokens[1]) else {
                    throw FLAC2MP3Error.malformedCue(url, "Invalid INDEX declaration on line \(lineNumber + 1).")
                }
                guard currentTrack != nil else {
                    throw FLAC2MP3Error.malformedCue(url, "INDEX appears before TRACK on line \(lineNumber + 1).")
                }
                let seconds = try parseTimestamp(tokens[2], url: url, line: lineNumber + 1)
                if index == 1 {
                    currentTrack?.index01 = seconds
                } else if index == 0 {
                    currentTrack?.index00 = seconds
                }
            case "TITLE":
                guard tokens.count >= 2 else { continue }
                if currentTrack != nil {
                    currentTrack?.title = tokens.dropFirst().joined(separator: " ")
                } else {
                    albumTitle = tokens.dropFirst().joined(separator: " ")
                }
            case "PERFORMER":
                guard tokens.count >= 2 else { continue }
                if currentTrack != nil {
                    currentTrack?.performer = tokens.dropFirst().joined(separator: " ")
                } else {
                    albumPerformer = tokens.dropFirst().joined(separator: " ")
                }
            case "DATE":
                if tokens.count >= 2, currentTrack == nil { albumDate = tokens.dropFirst().joined(separator: " ") }
            case "GENRE":
                if tokens.count >= 2, currentTrack == nil { albumGenre = tokens.dropFirst().joined(separator: " ") }
            case "REM":
                guard tokens.count >= 3 else { continue }
                let remCommand = tokens[1].uppercased()
                let value = tokens.dropFirst(2).joined(separator: " ")
                if currentTrack == nil {
                    if remCommand == "DATE" { albumDate = value }
                    if remCommand == "GENRE" { albumGenre = value }
                }
            default:
                continue
            }
        }

        try finishCurrentTrack()
        guard !workingTracks.isEmpty else {
            throw FLAC2MP3Error.malformedCue(url, "No audio tracks were found.")
        }

        let albumMetadata = TrackMetadata(
            artist: albumPerformer,
            albumArtist: albumPerformer,
            album: albumTitle,
            date: albumDate,
            genre: albumGenre,
            trackTotal: workingTracks.count
        )

        var tracks: [CueTrack] = []
        for index in workingTracks.indices {
            let item = workingTracks[index]
            guard let start = item.index01 else {
                throw FLAC2MP3Error.malformedCue(url, "Track \(item.number) has no INDEX 01 entry.")
            }
            let next = workingTracks.dropFirst(index + 1).first
            let end: Double?
            if let next, next.sourceURL.standardizedFileURL == item.sourceURL.standardizedFileURL {
                guard let nextStart = next.index01, nextStart > start else {
                    throw FLAC2MP3Error.malformedCue(url, "Track boundaries are not increasing near track \(item.number).")
                }
                end = nextStart
            } else {
                end = nil
            }
            let metadata = TrackMetadata(
                artist: item.performer ?? albumPerformer,
                albumArtist: albumPerformer,
                album: albumTitle,
                title: item.title,
                date: albumDate,
                genre: albumGenre,
                discNumber: item.discNumber,
                trackNumber: item.number,
                trackTotal: workingTracks.count
            )
            tracks.append(CueTrack(number: item.number, sourceURL: item.sourceURL, startSeconds: start, endSeconds: end, metadata: metadata))
        }

        return CueDocument(url: url, albumMetadata: albumMetadata, tracks: tracks)
    }

    private static func readText(url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FLAC2MP3Error.unableToRead(url, error.localizedDescription)
        }
        let encodings: [String.Encoding] = [.utf8, .windowsCP1252, .windowsCP1251, .isoLatin1]
        for encoding in encodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        throw FLAC2MP3Error.malformedCue(url, "The file is not readable as UTF-8 or a supported legacy encoding.")
    }

    private static func parseTimestamp(_ value: String, url: URL, line: Int) throws -> Double {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              let frames = Double(parts[2]),
              minutes >= 0,
              seconds >= 0,
              seconds < 60,
              frames >= 0,
              frames < 75 else {
            throw FLAC2MP3Error.malformedCue(url, "Invalid timestamp \(value) on line \(line).")
        }
        return (minutes * 60) + seconds + (frames / 75)
    }

    private static func tokenize(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

}

private struct WorkingTrack {
    let number: Int
    let sourceURL: URL
    var title: String? = nil
    var performer: String? = nil
    var discNumber: String? = nil
    var index00: Double? = nil
    var index01: Double? = nil

    init(number: Int, sourceURL: URL) {
        self.number = number
        self.sourceURL = sourceURL
    }
}
