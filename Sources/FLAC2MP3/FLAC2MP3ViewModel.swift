import AppKit
import Combine
import Foundation

@MainActor
final class FLAC2MP3ViewModel: ObservableObject {
    @Published var folderPath: String = "/Volumes/MUSIK 2026"
    @Published var recursive = true
    @Published var quality: MP3Quality = .v0VBR
    @Published var useMusicBrainz = true
    @Published var useCoverJPG = false
    @Published var requestIntervalText = "1.0"
    @Published var ignoreMissingEnrichment = false
    @Published private(set) var isRunning = false
    @Published private(set) var isScanning = false
    @Published private(set) var currentFile = ""
    @Published private(set) var currentIndex = 0
    @Published private(set) var totalJobs = 0
    @Published private(set) var currentProgress: Double?
    @Published private(set) var convertedCount = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var status = "Ready"
    @Published private(set) var logLines: [String] = []
    @Published var errorMessage: String?

    private var worker: Task<ConversionSummary, Error>?

    var requestIntervalSeconds: Double? {
        let normalized = requestIntervalText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 1.0, value <= 60.0 else { return nil }
        return value
    }

    var canStart: Bool {
        !isRunning &&
            !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (!useMusicBrainz || requestIntervalSeconds != nil)
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Music Folder"
        panel.directoryURL = URL(fileURLWithPath: folderPath)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.folderPath = url.path }
        }
    }

    func start() {
        guard canStart else { return }
        let path = (folderPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: path).standardizedFileURL
        let interval: Double
        if useMusicBrainz {
            guard let requestIntervalSeconds else {
                errorMessage = FLAC2MP3Error.invalidRequestInterval(Double(requestIntervalText) ?? 0).localizedDescription
                return
            }
            interval = requestIntervalSeconds
        } else {
            // The interval is inactive without MusicBrainz. Keep a valid value in
            // the immutable settings object for the worker, even if the disabled
            // text field currently contains an invalid value.
            interval = requestIntervalSeconds ?? 1.0
        }
        let settings = ConversionSettings(
            rootURL: rootURL,
            recursive: recursive,
            quality: quality,
            requestIntervalSeconds: interval,
            useMusicBrainz: useMusicBrainz,
            useCoverJPG: useCoverJPG,
            ignoreMissingEnrichment: ignoreMissingEnrichment
        )

        errorMessage = nil
        isRunning = true
        isScanning = true
        status = "Scanning…"
        currentFile = ""
        currentIndex = 0
        totalJobs = 0
        currentProgress = nil
        convertedCount = 0
        skippedCount = 0
        logLines.removeAll(keepingCapacity: true)
        appendLog("Starting scan: \(rootURL.path)")
        appendLog("Recursive: \(settings.recursive ? "yes" : "no"); quality: \(settings.quality.rawValue)")
        appendLog("Use same-directory cover.jpg: \(settings.useCoverJPG ? "yes" : "no")")
        if settings.useMusicBrainz {
            appendLog("MusicBrainz metadata/cover: yes; wait: \(String(format: "%.2f", settings.requestIntervalSeconds)) s; ignore missing metadata/cover: \(settings.ignoreMissingEnrichment ? "yes" : "no")")
        } else {
            appendLog("MusicBrainz metadata/cover: no; using local metadata and artwork only.")
        }

        let sink = EventSink { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let task = Task.detached(priority: .userInitiated) {
            let scanner = LibraryScanner()
            let plan = try scanner.scan(
                rootURL: settings.rootURL,
                recursive: settings.recursive,
                useCoverJPG: settings.useCoverJPG
            ) { path, discovered in
                if Task.isCancelled { return }
                sink.send(.scanning(path: path, discovered: discovered))
            }
            try Task.checkCancellation()
            let service = ConversionService()
            return try await service.convert(
                plan: plan,
                quality: settings.quality,
                requestIntervalSeconds: settings.requestIntervalSeconds,
                enrichMetadata: settings.useMusicBrainz,
                useCoverJPG: settings.useCoverJPG,
                ignoreMissingEnrichment: settings.ignoreMissingEnrichment
            ) { event in
                sink.send(event)
            }
        }
        worker = task
        Task { @MainActor [weak self] in
            do {
                let summary = try await task.value
                self?.finish(summary: summary)
            } catch is CancellationError {
                self?.finishCancelled()
            } catch {
                self?.finish(error: error)
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        status = "Cancelling…"
        appendLog("Cancellation requested…")
        worker?.cancel()
    }

    func clearLog() {
        guard !isRunning else { return }
        logLines.removeAll()
    }

    private func handle(_ event: ConversionEvent) {
        guard isRunning else { return }
        switch event {
        case let .scanning(path, discovered):
            isScanning = true
            status = "Scanning (\(discovered) FLAC found)…"
            currentFile = path
        case let .planReady(total, skipped):
            isScanning = false
            totalJobs = total
            status = total == 0 ? "No FLAC files found" : "Ready to convert \(total) file(s)"
            appendLog("Queue contains \(total) output track(s); \(skipped) already exist and will be skipped.")
        case let .waiting(seconds):
            currentProgress = nil
            status = "Waiting \(String(format: "%.2f", seconds)) s before the next MusicBrainz request…"
            appendLog("Waiting \(String(format: "%.2f", seconds)) s before the next MusicBrainz request.")
        case let .metadataLookup(path):
            currentFile = path
            status = "Looking up MusicBrainz metadata…"
        case let .artworkLookup(path):
            status = "Downloading cover art for release \(path)…"
        case let .started(index, total, job):
            isScanning = false
            currentIndex = index
            totalJobs = total
            currentProgress = 0
            currentFile = job.sourceURL.path
            status = "Processing \(index) of \(total)"
            appendLog("Processing [\(index)/\(total)]: \(job.sourceURL.path) → \(job.outputURL.lastPathComponent)")
        case let .progress(index, total, fraction):
            currentIndex = index
            totalJobs = total
            currentProgress = fraction
        case let .converted(index, total, job):
            currentIndex = index
            totalJobs = total
            currentProgress = 1
            convertedCount += 1
            appendLog("Converted: \(job.outputURL.path)")
        case let .skipped(index, total, job):
            currentIndex = index
            totalJobs = total
            currentProgress = 1
            skippedCount += 1
            appendLog("Skipped (already exists): \(job.outputURL.path)")
        case let .log(message):
            appendLog(message)
        }
    }

    private func finish(summary: ConversionSummary) {
        isRunning = false
        isScanning = false
        worker = nil
        currentProgress = totalJobs > 0 ? 1 : nil
        status = "Finished: \(summary.converted) converted, \(summary.skipped) skipped"
        convertedCount = summary.converted
        skippedCount = summary.skipped
        appendLog(status)
    }

    private func finishCancelled() {
        isRunning = false
        isScanning = false
        worker = nil
        currentProgress = nil
        status = "Cancelled"
        appendLog("Cancelled. Completed outputs were kept; the active temporary output was removed.")
    }

    private func finish(error: Error) {
        isRunning = false
        isScanning = false
        worker = nil
        currentProgress = nil
        status = "Stopped because of an error"
        let message = error.localizedDescription
        appendLog("ERROR: \(message)")
        errorMessage = message
    }

    private func appendLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime]
        logLines.append("[\(formatter.string(from: Date()))] \(message)")
        if logLines.count > 2_000 { logLines.removeFirst(logLines.count - 2_000) }
    }
}

private final class EventSink: @unchecked Sendable {
    private let callback: (ConversionEvent) -> Void

    init(callback: @escaping (ConversionEvent) -> Void) {
        self.callback = callback
    }

    func send(_ event: ConversionEvent) {
        callback(event)
    }
}
