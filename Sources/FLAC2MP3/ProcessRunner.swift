import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

final class ProcessRunner {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var cancellationRequested = false

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = activeProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    func run(
        executable: URL,
        arguments: [String],
        onProgressTime: ((Double) -> Void)? = nil
    ) async throws -> ProcessResult {
        resetCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                start(
                    executable: executable,
                    arguments: arguments,
                    onProgressTime: onProgressTime,
                    continuation: continuation
                )
            }
        }, onCancel: {
            cancel()
        })
    }

    private func resetCancellation() {
        lock.lock()
        cancellationRequested = false
        lock.unlock()
    }

    private func start(
        executable: URL,
        arguments: [String],
        onProgressTime: ((Double) -> Void)?,
        continuation: CheckedContinuation<ProcessResult, Error>
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCollector = OutputCollector(onLine: { line in
            guard let separator = line.firstIndex(of: "=") else { return }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            if key == "out_time_ms", let milliseconds = Double(value) {
                onProgressTime?(milliseconds / 1_000_000)
            } else if key == "progress", value == "end" {
                onProgressTime?(Double.greatestFiniteMagnitude)
            }
        })
        let stderrCollector = OutputCollector(onLine: nil)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutCollector] handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutCollector.consume(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [stderrCollector] handle in
            let data = handle.availableData
            if !data.isEmpty { stderrCollector.consume(data) }
        }

        lock.lock()
        activeProcess = process
        let shouldCancel = cancellationRequested
        lock.unlock()

        process.terminationHandler = { [weak self] process in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdoutCollector.consume(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrCollector.consume(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            let result = ProcessResult(
                status: process.terminationStatus,
                standardOutput: stdoutCollector.value,
                standardError: stderrCollector.value
            )

            self?.lock.lock()
            let wasCancelled = self?.cancellationRequested ?? false
            if self?.activeProcess === process { self?.activeProcess = nil }
            self?.lock.unlock()

            if wasCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(returning: result)
            }
        }

        do {
            try process.run()
            if shouldCancel { process.terminate() }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            activeProcess = nil
            lock.unlock()
            continuation.resume(throwing: error)
        }
    }
}

private final class OutputCollector {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    func consume(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        pending += String(decoding: newData, as: UTF8.self)
        let lines = pending.components(separatedBy: .newlines)
        pending = lines.last ?? ""
        lock.unlock()
        for line in lines.dropLast() where !line.isEmpty { onLine?(line) }
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FFmpegLocator {
    static func locate() async throws -> URL {
        var candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/ffmpeg" })
        }
        var uniqueCandidates: [String] = []
        for candidate in candidates where !uniqueCandidates.contains(candidate) { uniqueCandidates.append(candidate) }

        for candidate in uniqueCandidates {
            let url = URL(fileURLWithPath: candidate)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let runner = ProcessRunner()
            if let result = try? await runner.run(executable: url, arguments: ["-hide_banner", "-nostdin", "-encoders"]),
               result.status == 0,
               (result.standardOutput + result.standardError).contains("libmp3lame") {
                return url
            }
        }
        throw FLAC2MP3Error.ffmpegNotFound(uniqueCandidates)
    }
}
