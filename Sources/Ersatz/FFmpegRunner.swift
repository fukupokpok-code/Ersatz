#if os(macOS)
import Darwin
import ErsatzCore
import Foundation

enum PlaybackPreferences {
    static let pathKey = "ffmpegPath"
    static let cacheKey = "playbackCacheGigabytes"

    static func customPath() -> String? {
        let raw = UserDefaults.standard.string(forKey: pathKey) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func tools() -> FFmpegTools? {
        FFmpegLocator.locate(
            customPath: customPath(),
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

}

enum FFmpegRunnerError: LocalizedError, Equatable {
    case notInstalled
    case probeFailed(String)
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ffmpeg is not installed"
        case .probeFailed(let detail):
            return detail.isEmpty ? "ffprobe could not read this file." : detail
        case .unsupported(let reason):
            return reason
        case .failed(let detail):
            return detail.isEmpty ? "ffmpeg failed." : detail
        }
    }
}

struct ExternalContainerExtractor: MetadataExtracting {
    func extract(from url: URL, kind: MediaType) async -> MediaMetadata {
        if Task.isCancelled {
            return MediaMetadata(formatName: FormatNames.preferred(forExtension: url.pathExtension))
        }
        if kind == .video, ExternalPlayback.needsExternalPlayer(path: url.path), let tools = PlaybackPreferences.tools() {
            do {
                let report = try await FFmpegRunner.probe(ffprobe: tools.ffprobePath, input: url)
                if report.videoCodec != nil || report.width != nil || report.duration != nil {
                    return report.metadata(formatName: FormatNames.preferred(forExtension: url.pathExtension))
                }
            } catch is CancellationError {
                return MediaMetadata(formatName: FormatNames.preferred(forExtension: url.pathExtension))
            } catch {
                // Keep the catalog row as Video and let AVFoundation try.
            }
        }
        return await MacMetadataExtractor().extract(from: url, kind: kind)
    }
}

enum FFmpegRunner {
    static func probe(ffprobe: String, input: URL) async throws -> ProbeReport {
        let runner = FFmpegProcess()
        let box = DataBuffer()
        let result = try await withTaskCancellationHandler {
            try await runner.execute(
                executable: ffprobe,
                arguments: FFmpegArguments.probe(input: input.path)
            ) { data in
                box.append(data)
            }
        } onCancel: {
            runner.terminate()
        }
        guard result.status == 0 else {
            throw FFmpegRunnerError.probeFailed(clip(result.standardError, fallback: "ffprobe exited with status \(result.status)."))
        }
        guard let report = FFProbeJSON.parse(box.data()) else {
            throw FFmpegRunnerError.probeFailed("ffprobe did not return stream information.")
        }
        return report
    }

    static func materialize(
        tools: FFmpegTools,
        source: URL,
        fileSize: Int64,
        modifiedAt: Date,
        cache: PlaybackCache,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (PlaybackProgress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        if let hit = cache.existing(path: source.path, fileSize: fileSize, modifiedAt: modifiedAt) {
            return hit
        }
        let destination = cache.fileURL(path: source.path, fileSize: fileSize, modifiedAt: modifiedAt)
        let partial = URL(fileURLWithPath: destination.path + ".partial")
        if PlaybackPaths.sameFile(source.path, destination.path) || PlaybackPaths.sameFile(source.path, partial.path) {
            throw FFmpegRunnerError.failed("Refusing to overwrite the original file.")
        }
        onProgress(PlaybackProgress(stage: .probing, fraction: nil))
        let report = try await probe(ffprobe: tools.ffprobePath, input: source)
        let stage: PlaybackProgress.Stage
        switch report.plan {
        case .remux:
            stage = .remuxing
        case .transcode:
            stage = .transcoding
        case .unsupported(let reason):
            throw FFmpegRunnerError.unsupported(reason)
        }
        guard let arguments = FFmpegArguments.make(plan: report.plan, input: source.path, output: partial.path) else {
            throw FFmpegRunnerError.failed("Refusing to overwrite the original file.")
        }
        onProgress(PlaybackProgress(stage: stage, fraction: nil))
        if FileManager.default.fileExists(atPath: partial.path) {
            try? FileManager.default.removeItem(at: partial)
        }
        let relay = ProgressRelay(duration: report.duration ?? 0)
        let runner = FFmpegProcess()
        let result: FFmpegProcessResult
        do {
            result = try await withTaskCancellationHandler {
                try await runner.execute(executable: tools.ffmpegPath, arguments: arguments) { data in
                    if let fraction = relay.ingest(data) {
                        onProgress(PlaybackProgress(stage: stage, fraction: fraction))
                    }
                }
            } onCancel: {
                runner.terminate()
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let written = FileManager.default.fileExists(atPath: partial.path)
        guard result.status == 0, written else {
            try? FileManager.default.removeItem(at: partial)
            throw FFmpegRunnerError.failed(clip(result.standardError, fallback: "ffmpeg exited with status \(result.status)."))
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: partial, to: destination)
        try? cache.enforceLimit(maxBytes: maxBytes, protecting: destination.path)
        onProgress(PlaybackProgress(stage: stage, fraction: 1))
        return destination
    }

    static func thumbnailJPEG(source: URL, maxSide: Int, duration: Double?) async -> Data? {
        guard let tools = PlaybackPreferences.tools() else { return nil }
        let seek: Double = if let duration, duration < 1.5 { 0 } else { 1 }
        if let data = await jpeg(ffmpeg: tools.ffmpegPath, source: source, maxSide: maxSide, seek: seek) {
            return data
        }
        guard seek != 0 else { return nil }
        return await jpeg(ffmpeg: tools.ffmpegPath, source: source, maxSide: maxSide, seek: 0)
    }

    private static func jpeg(ffmpeg: String, source: URL, maxSide: Int, seek: Double) async -> Data? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ersatz-frame-\(UUID().uuidString).jpg")
        let arguments = FFmpegArguments.thumbnail(
            input: source.path,
            output: output.path,
            seekSeconds: seek,
            maxSide: maxSide
        )
        let runner = FFmpegProcess()
        do {
            let result = try await withTaskCancellationHandler {
                try await runner.execute(executable: ffmpeg, arguments: arguments) { _ in }
            } onCancel: {
                runner.terminate()
            }
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: output)
                return nil
            }
            let data = try Data(contentsOf: output)
            try? FileManager.default.removeItem(at: output)
            return data.isEmpty ? nil : data
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }

    private static func clip(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.count <= 600 { return trimmed }
        return "…" + trimmed.suffix(599)
    }
}

private struct FFmpegProcessResult: Sendable {
    var status: Int32
    var standardError: String
}

/// Every ffmpeg or ffprobe child that is running, so quitting can stop them all.
final class FFmpegProcessRegistry: @unchecked Sendable {
    static let shared = FFmpegProcessRegistry()

    private let lock = NSLock()
    private var live: [ObjectIdentifier: FFmpegProcess] = [:]
    private var shuttingDown = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return live.count
    }

    /// Returns false once the app is quitting; the caller must not start the process.
    fileprivate func register(_ runner: FFmpegProcess) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shuttingDown else { return false }
        live[ObjectIdentifier(runner)] = runner
        return true
    }

    fileprivate func unregister(_ runner: FFmpegProcess) {
        lock.lock()
        live[ObjectIdentifier(runner)] = nil
        lock.unlock()
    }

    /// Sends SIGTERM to every live child, waits up to `grace` seconds, then SIGKILLs survivors.
    /// Refuses new launches afterwards. Returns how many children were running.
    @discardableResult
    func terminateAll(grace: TimeInterval = 1.0) -> Int {
        lock.lock()
        shuttingDown = true
        let runners = Array(live.values)
        lock.unlock()
        guard !runners.isEmpty else { return 0 }
        for runner in runners {
            runner.terminate()
        }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, runners.contains(where: { $0.isRunning }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        for runner in runners where runner.isRunning {
            runner.kill()
        }
        return runners.count
    }
}

fileprivate final class FFmpegProcess: @unchecked Sendable {
    private enum Part: Hashable {
        case stdout, stderr, exit
    }

    private let lock = NSLock()
    private let group = DispatchGroup()
    private var pending: Set<Part> = []
    private var process: Process?
    private var continuation: CheckedContinuation<FFmpegProcessResult, Error>?
    private var errors = DataBuffer()
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var cancelled = false
    private var status: Int32?
    private var launchError: Error?

    var isRunning: Bool {
        lock.lock()
        let process = self.process
        lock.unlock()
        return process?.isRunning ?? false
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func kill() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    func execute(
        executable: String,
        arguments: [String],
        onStdout: @escaping @Sendable (Data) -> Void
    ) async throws -> FFmpegProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            launch(executable: executable, arguments: arguments, onStdout: onStdout, continuation: continuation)
        }
    }

    /// The result is delivered only after stdout and stderr have both reached EOF
    /// and the process has exited, so no output is lost and no handler outlives the call.
    private func launch(
        executable: String,
        arguments: [String],
        onStdout: @escaping @Sendable (Data) -> Void,
        continuation: CheckedContinuation<FFmpegProcessResult, Error>
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        let stdout = outputPipe.fileHandleForReading
        let stderr = errorPipe.fileHandleForReading
        let errors = self.errors

        lock.lock()
        self.process = process
        self.continuation = continuation
        self.stdout = stdout
        self.stderr = stderr
        pending = [.stdout, .stderr, .exit]
        let alreadyCancelled = cancelled
        lock.unlock()
        for _ in 0..<3 { group.enter() }

        group.notify(queue: .global(qos: .utility)) { [self] in
            complete()
        }

        if alreadyCancelled || !FFmpegProcessRegistry.shared.register(self) {
            fail(CancellationError())
            return
        }

        stdout.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finish(.stdout)
            } else {
                onStdout(data)
            }
        }
        stderr.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finish(.stderr)
            } else {
                errors.append(data)
            }
        }
        process.terminationHandler = { [self] process in
            lock.lock()
            status = process.terminationStatus
            lock.unlock()
            finish(.exit)
            // A grandchild that inherited a pipe can keep it open after ffmpeg exits.
            // Do not wait on it forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
                closePipes()
            }
        }

        do {
            try process.run()
        } catch {
            fail(error)
            return
        }
        lock.lock()
        let cancelledDuringLaunch = cancelled
        lock.unlock()
        if cancelledDuringLaunch {
            process.terminate()
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        launchError = error
        lock.unlock()
        closePipes()
        finish(.exit)
    }

    private func closePipes() {
        lock.lock()
        let stdout = self.stdout
        let stderr = self.stderr
        lock.unlock()
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        finish(.stdout)
        finish(.stderr)
    }

    /// Leaves the group once per part, no matter how many times a part reports.
    private func finish(_ part: Part) {
        lock.lock()
        let removed = pending.remove(part) != nil
        lock.unlock()
        if removed { group.leave() }
    }

    private func complete() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        let status = self.status
        let error = launchError
        let stdout = self.stdout
        let stderrHandle = self.stderr
        lock.unlock()
        stdout?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdout?.close()
        try? stderrHandle?.close()
        FFmpegProcessRegistry.shared.unregister(self)
        guard let continuation else { return }
        if wasCancelled || error is CancellationError {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let error {
            continuation.resume(throwing: error)
            return
        }
        continuation.resume(returning: FFmpegProcessResult(status: status ?? 1, standardError: errors.string()))
    }
}

private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: FFmpegProgressParser

    init(duration: Double) {
        parser = FFmpegProgressParser(duration: duration)
    }

    func ingest(_ data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return parser.ingest(text)
    }
}

private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        if storage.count < 1_000_000 {
            storage.append(data.prefix(1_000_000 - storage.count))
        }
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func string() -> String {
        String(data: data(), encoding: .utf8) ?? ""
    }
}
#endif
