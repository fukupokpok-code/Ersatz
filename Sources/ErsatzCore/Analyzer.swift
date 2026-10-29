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

public protocol ImageScoring: Sendable {
    func signals(for url: URL, kind: MediaType) async -> ImageSignals
}

public struct EmptyImageScoring: ImageScoring {
    public init() {}
    public func signals(for url: URL, kind: MediaType) async -> ImageSignals {
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

    public init(workerCount: Int? = nil) {
        self.workerCount = max(2, workerCount ?? ProcessInfo.processInfo.activeProcessorCount)
    }

    public func analyze(
        database: MediaDatabase,
        scoring: any ImageScoring = EmptyImageScoring(),
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        let pending = try await database.pendingAnalysis()
        let total = pending.count
        var finished = 0
        var iterator = pending.makeIterator()
        let limit = min(workerCount, max(total, 1))
        var batch: [AnalysisUpdate] = []
        let sizeBuckets = Dictionary(grouping: pending, by: \.fileSize)

        try await withThrowingTaskGroup(of: AnalysisUpdate.self) { group in
            func enqueue() {
                guard let item = iterator.next() else { return }
                group.addTask {
                    try await Self.inspect(item, scoring: scoring, sizePeers: sizeBuckets[item.fileSize]?.count ?? 1)
                }
            }
            for _ in 0..<limit { enqueue() }
            for try await update in group {
                batch.append(update)
                finished += 1
                if batch.count >= 60 {
                    try await database.saveAnalysis(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                if finished % 25 == 0 || finished == total {
                    progress(finished, total)
                }
                enqueue()
            }
        }
        if !batch.isEmpty {
            try await database.saveAnalysis(batch)
        }
    }

    private static func inspect(
        _ item: PendingAnalysis,
        scoring: any ImageScoring,
        sizePeers: Int
    ) async throws -> AnalysisUpdate {
        let url = URL(fileURLWithPath: item.path)
        let partial = try? SHA256Digest.hexFile(at: url, maxBytes: 64 * 1024)
        var full: String?
        if sizePeers > 1 {
            full = try? SHA256Digest.hexFile(at: url)
        } else {
            full = partial
        }
        var signals = ImageSignals()
        if item.kind == .photo || item.kind == .raw {
            signals = await scoring.signals(for: url, kind: item.kind)
        }
        let screenshot = ScreenshotDetector.matches(
            filename: item.filename,
            formatName: item.formatName,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            hasCameraModel: item.hasCameraModel
        )
        let slip = BankSlipClassifier.isSlip(text: signals.recognizedText, hasQR: signals.hasQR)
        return AnalysisUpdate(
            mediaID: item.id,
            partialHash: partial,
            contentHash: full,
            perceptualHash: signals.perceptualHash,
            sharpness: signals.sharpness,
            isScreenshot: screenshot,
            hasQR: signals.hasQR,
            isBankSlip: slip,
            analyzedMTime: item.modifiedAtMS
        )
    }
}
