import Foundation

struct LibraryScanner {
    private struct CueCandidate {
        let cueURL: URL
        let document: CueDocument
    }

    func scan(rootURL: URL, recursive: Bool, onProgress: ((String, Int) -> Void)? = nil) throws -> ConversionPlan {
        let rootValues: URLResourceValues
        do {
            rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw FLAC2MP3Error.unableToRead(rootURL, error.localizedDescription)
        }
        guard rootValues.isDirectory == true else { throw FLAC2MP3Error.rootIsNotDirectory(rootURL) }

        let files = try collectFiles(rootURL: rootURL, recursive: recursive, onProgress: onProgress)
        let flacs = files.filter { $0.pathExtension.lowercased() == "flac" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let cues = files.filter { $0.pathExtension.lowercased() == "cue" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var flacByKey: [String: URL] = [:]
        for flac in flacs { flacByKey[pathKey(flac)] = flac }

        var candidatesByFLAC: [String: [CueCandidate]] = [:]
        for cue in cues {
            let document = try CueParser.parse(url: cue)
            for referencedURL in document.referencedFLACURLs {
                let key = pathKey(referencedURL)
                guard flacByKey[key] != nil else {
                    throw FLAC2MP3Error.cueReferencesMissingFile(cue, referencedURL.path)
                }
                candidatesByFLAC[key, default: []].append(CueCandidate(cueURL: cue, document: document))
            }
        }

        var jobs: [ConversionJob] = []
        var consumedFLACs = Set<String>()
        for flac in flacs {
            let key = pathKey(flac)
            let candidates = candidatesByFLAC[key] ?? []
            if let candidate = try chooseCandidate(for: flac, candidates: candidates) {
                let cover = findCover(in: flac.deletingLastPathComponent())
                let tracks = candidate.document.tracks.filter { pathKey($0.sourceURL) == key }
                for track in tracks {
                    let outputName = trackFilename(track: track, albumArtist: candidate.document.albumMetadata.artist)
                    let outputURL = flac.deletingLastPathComponent().appendingPathComponent(outputName)
                    jobs.append(ConversionJob(
                        sourceURL: flac,
                        outputURL: outputURL,
                        metadata: track.metadata,
                        startSeconds: track.startSeconds,
                        endSeconds: track.endSeconds,
                        coverURL: cover
                    ))
                }
                consumedFLACs.insert(key)
            }
        }

        for flac in flacs where !consumedFLACs.contains(pathKey(flac)) {
            let outputURL = flac.deletingPathExtension().appendingPathExtension("mp3")
            jobs.append(ConversionJob(sourceURL: flac, outputURL: outputURL, coverURL: findCover(in: flac.deletingLastPathComponent())))
        }

        try validateOutputConflicts(jobs)
        return ConversionPlan(jobs: jobs)
    }

    private func collectFiles(rootURL: URL, recursive: Bool, onProgress: ((String, Int) -> Void)?) throws -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []
        var discovered = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]

        func accept(_ url: URL) throws {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                throw FLAC2MP3Error.unableToRead(url, error.localizedDescription)
            }
            if values.isSymbolicLink == true || values.isDirectory == true { return }
            let name = values.name ?? url.lastPathComponent
            guard !name.hasPrefix("._"), !name.hasPrefix(".") else { return }
            let ext = url.pathExtension.lowercased()
            guard ext == "flac" || ext == "cue" else { return }
            result.append(url)
            if ext == "flac" {
                discovered += 1
                onProgress?(url.path, discovered)
            }
        }

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw FLAC2MP3Error.unableToRead(rootURL, "The folder could not be enumerated.")
            }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                try accept(url)
            }
        } else {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw FLAC2MP3Error.unableToRead(rootURL, error.localizedDescription)
            }
            for child in children { try accept(child) }
        }
        return result
    }

    private func chooseCandidate(for flac: URL, candidates: [CueCandidate]) throws -> CueCandidate? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        let flacStem = flac.deletingPathExtension().lastPathComponent.lowercased()
        let exact = candidates.filter { $0.cueURL.deletingPathExtension().lastPathComponent.lowercased() == flacStem }
        if exact.count == 1 { return exact[0] }
        throw FLAC2MP3Error.ambiguousCue(flac, candidates.map(\.cueURL))
    }

    private func findCover(in directory: URL) -> URL? {
        let names = Set(["cover", "folder", "front"])
        let extensions = Set(["jpg", "jpeg", "png"])
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children
            .filter { names.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .first
    }

    private func trackFilename(track: CueTrack, albumArtist: String?) -> String {
        let number = String(track.number).leftPadded(to: 2, with: "0")
        let artist = track.metadata.artist ?? albumArtist ?? "Unknown Artist"
        let title = track.metadata.title ?? "Track \(number)"
        return sanitizeFilename("\(number) - \(artist) - \(title).mp3")
    }

    private func sanitizeFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let scalars = value.unicodeScalars.map { forbidden.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
        let cleaned = scalars.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled.mp3" : trimmed
    }

    private func validateOutputConflicts(_ jobs: [ConversionJob]) throws {
        var outputs: [String: URL] = [:]
        for job in jobs {
            let key = pathKey(job.outputURL)
            if outputs[key] != nil { throw FLAC2MP3Error.outputConflict(job.outputURL) }
            outputs[key] = job.outputURL
        }
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
