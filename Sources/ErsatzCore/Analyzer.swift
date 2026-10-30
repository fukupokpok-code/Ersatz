import Foundation

public struct ImageSignals: Sendable, Equatable {
    public var perceptualHash: UInt64?
    public var sharpness: Double?
    public var hasQR: Bool
    public var recognizedText: String

    public init(
        perceptualHash: UInt64? = nil,
        sharpness: Double? = nil,
        hasQR: Bool = false,
        recognizedText: String = ""
    ) {
        self.perceptualHash = perceptualHash
        self.sharpness = sharpness
        self.hasQR = hasQR
        self.recognizedText = recognizedText
    }
}

/// The separately cached pieces of analysis. Each smart filter asks only for what it
/// shows, so opening Screenshots never runs text recognition, for example.
public struct AnalysisParts: OptionSet, Sendable, Hashable {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }

    /// Filename, size and camera heuristics. Cheap: no file reads.
    public static let screenshot = AnalysisParts(rawValue: 1)
    /// SHA-256 of the head, and of the whole file when another file has the same size.
    public static let hashes = AnalysisParts(rawValue: 2)
    /// Difference hash for near-duplicates.
    public static let perceptual = AnalysisParts(rawValue: 4)
    /// Blur score (`BlurDetector`) for the Blurry filter.
    public static let sharpness = AnalysisParts(rawValue: 8)
    /// Vision barcode detection.
    public static let qr = AnalysisParts(rawValue: 16)
    /// Vision text recognition and the bank slip classifier (also needs `qr`).
    public static let bankSlip = AnalysisParts(rawValue: 32)

    public static let duplicates: AnalysisParts = [.hashes, .perceptual]
    public static let all: AnalysisParts = [.screenshot, .hashes, .perceptual, .sharpness, .qr, .bankSlip]

    /// Parts that need pixels decoded (and so only apply to photos and RAW files).
    public static let imageParts: AnalysisParts = [.perceptual, .sharpness, .qr, .bankSlip]

    /// The full set to compute when `self` is requested: bank slips use the QR result.
    public var closed: AnalysisParts {
        contains(.bankSlip) ? union(.qr) : self
    }
}

/// What the catalog already knows about a file, so scoring can skip slow steps.
public struct ScoringContext: Sendable, Equatable {
    public var hasCameraModel: Bool
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(hasCameraModel: Bool = false, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.hasCameraModel = hasCameraModel
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public protocol ImageScoring: Sendable {
    /// Computes only the signals in `parts`; others stay at their defaults.
    func signals(for url: URL, kind: MediaType, parts: AnalysisParts) async -> ImageSignals
    /// Same, with catalog facts. The default ignores them.
    func signals(for url: URL, kind: MediaType, parts: AnalysisParts, context: ScoringContext) async -> ImageSignals
}

extension ImageScoring {
    public func signals(for url: URL, kind: MediaType, parts: AnalysisParts, context: ScoringContext) async -> ImageSignals {
        await signals(for: url, kind: kind, parts: parts)
    }
}

public struct EmptyImageScoring: ImageScoring {
    public init() {}
    public func signals(for url: URL, kind: MediaType, parts: AnalysisParts) async -> ImageSignals {
        ImageSignals()
    }
}

public struct PendingAnalysis: Sendable {
    public var id: Int64
    public var path: String
    public var filename: String
    public var kind: MediaType
    public var fileSize: Int64
    public var modifiedAtMS: Int64
    public var formatName: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var hasCameraModel: Bool
}

public struct LibraryAnalyzer: Sendable {
    public var workerCount: Int
    /// Results are saved this many at a time; each save is visible to the filters at once.
    public var batchSize: Int

    public init(workerCount: Int? = nil, batchSize: Int = 20) {
        self.workerCount = max(2, workerCount ?? ProcessInfo.processInfo.activeProcessorCount)
        self.batchSize = max(1, batchSize)
    }

    /// Analyzes what is still missing for `parts` and caches it in the database.
    /// Cancelling the calling task stops it at once: queued items never start, items
    /// waiting for a gate slot stop waiting, and an item cancelled mid-way is dropped rather
    /// than saved half-done. Finished batches stay saved, so the next request picks up
    /// where this one stopped. `scope` limits the pass to one library.
    /// With a `gate`, every item runs in its background lane, so thumbnails and the
    /// indexer always go first.
    public func analyze(
        database: MediaDatabase,
        parts requested: AnalysisParts = .all,
        scoring: any ImageScoring = EmptyImageScoring(),
        gate: WorkGate? = nil,
        scope: LibraryScope? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        saved: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws {
        let parts = requested.closed
        let pending = try await database.pendingAnalysis(parts: parts, scope: scope)
        try Task.checkCancellation()
        let total = pending.count
        progress(0, total)
        guard total > 0 else { return }
        let sizes = parts.contains(.hashes) ? try await database.fileSizeCounts() : [:]
        var finished = 0
        var iterator = pending.makeIterator()
        let limit = min(workerCount, total)
        var batch: [AnalysisUpdate] = []

        try await withThrowingTaskGroup(of: AnalysisUpdate.self) { group in
            func enqueue() {
                guard !Task.isCancelled, let item = iterator.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    let peers = sizes[item.fileSize] ?? 1
                    if let gate {
                        return try await gate.runCancellable(.background) {
                            try await Self.inspect(item, parts: parts, scoring: scoring, sizePeers: peers)
                        }
                    }
                    return try await Self.inspect(item, parts: parts, scoring: scoring, sizePeers: peers)
                }
            }
            for _ in 0..<limit { enqueue() }
            do {
                for try await update in group {
                    batch.append(update)
                    finished += 1
                    if batch.count >= batchSize {
                        try await database.saveAnalysis(batch)
                        saved(batch.count)
                        batch.removeAll(keepingCapacity: true)
                    }
                    if finished % 10 == 0 || finished == total {
                        progress(finished, total)
                    }
                    enqueue()
                }
            } catch {
                // Keep what finished before the cancel.
                if (try? await database.saveAnalysis(batch)) != nil, !batch.isEmpty {
                    saved(batch.count)
                }
                batch.removeAll()
                throw error
            }
        }
        if !batch.isEmpty {
            try await database.saveAnalysis(batch)
            saved(batch.count)
        }
        try Task.checkCancellation()
    }

    static func inspect(
        _ item: PendingAnalysis,
        parts: AnalysisParts,
        scoring: any ImageScoring,
        sizePeers: Int
    ) async throws -> AnalysisUpdate {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: item.path)
        var partial: String?
        var full: String?
        if parts.contains(.hashes) {
            partial = try? SHA256Digest.hexFile(at: url, maxBytes: 64 * 1024)
            if sizePeers > 1 {
                full = try? SHA256Digest.hexFile(at: url)
            } else {
                full = partial
            }
        }
        var signals = ImageSignals()
        let imageParts = parts.intersection(.imageParts)
        if !imageParts.isEmpty, item.kind == .photo || item.kind == .raw {
            let context = ScoringContext(
                hasCameraModel: item.hasCameraModel,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight
            )
            try Task.checkCancellation()
            signals = await scoring.signals(for: url, kind: item.kind, parts: imageParts, context: context)
            // A scorer that noticed the cancel returns early with signals missing.
            // Saving those would mark the file analyzed with wrong answers.
            try Task.checkCancellation()
        }
        let screenshot = parts.contains(.screenshot) && ScreenshotDetector.matches(
            filename: item.filename,
            formatName: item.formatName,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            hasCameraModel: item.hasCameraModel
        )
        let slip = parts.contains(.bankSlip)
            && BankSlipClassifier.isSlip(text: signals.recognizedText, hasQR: signals.hasQR)
        return AnalysisUpdate(
            mediaID: item.id,
            partialHash: partial,
            contentHash: full,
            perceptualHash: signals.perceptualHash,
            sharpness: signals.sharpness,
            isScreenshot: screenshot,
            hasQR: signals.hasQR,
            isBankSlip: slip,
            analyzedMTime: item.modifiedAtMS,
            parts: parts
        )
    }
}
