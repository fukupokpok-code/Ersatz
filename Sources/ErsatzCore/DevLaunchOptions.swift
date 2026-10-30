import Foundation

/// Developer-only launch options for running Ersatz against a throwaway catalog, for
/// example to take README screenshots, without touching the real library.
///
/// Give a data directory with the environment variable `ERSATZ_DATA_DIR` or the launch
/// argument `-ErsatzDataDir <path>`. The catalog, caches and activity log then live
/// under it instead of `~/Library`. Only with a data directory set, these also work:
///
/// * `-ErsatzAddFolder <path>` (repeatable): add the folder to that catalog on launch.
/// * `-ErsatzStartFilter <name>`: open a sidebar place, e.g. `duplicates` or `blurry`.
/// * `-ErsatzOpenViewer`: open the viewer on the first item once the grid has items.
/// * `-ErsatzWindowSize <width>x<height>`: size the main window, in points.
/// * `-ErsatzSnapshot <path.png>`: after `-ErsatzSnapshotDelay <seconds>` (default 10),
///   save a PNG of the app's own main window there. The app draws the image itself, so
///   no Screen Recording permission is needed.
///
/// Without a data directory every other option is ignored, so a normal launch never
/// changes behaviour.
public struct DevLaunchOptions: Sendable, Equatable {
    public static let environmentKey = "ERSATZ_DATA_DIR"

    public var dataDirectory: URL?
    public var addFolders: [URL] = []
    public var startFilter: String?
    public var openViewer = false
    public var windowSize: WindowSize?
    public var snapshotURL: URL?
    public var snapshotDelay: Double = DevLaunchOptions.defaultSnapshotDelay

    public static let defaultSnapshotDelay: Double = 10

    public struct WindowSize: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// "1440x900" -> 1440 by 900. Sizes under 400 by 300 are refused.
        public init?(parsing text: String) {
            let parts = text.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  width >= 400, height >= 300 else { return nil }
            self.init(width: width, height: height)
        }
    }

    public init(
        dataDirectory: URL? = nil,
        addFolders: [URL] = [],
        startFilter: String? = nil,
        openViewer: Bool = false,
        windowSize: WindowSize? = nil,
        snapshotURL: URL? = nil,
        snapshotDelay: Double = DevLaunchOptions.defaultSnapshotDelay
    ) {
        self.dataDirectory = dataDirectory
        self.addFolders = addFolders
        self.startFilter = startFilter
        self.openViewer = openViewer
        self.windowSize = windowSize
        self.snapshotURL = snapshotURL
        self.snapshotDelay = snapshotDelay
    }

    /// The options this process was launched with.
    public static let current = parse(
        environment: ProcessInfo.processInfo.environment,
        arguments: ProcessInfo.processInfo.arguments
    )

    public static func parse(environment: [String: String], arguments: [String]) -> DevLaunchOptions {
        var options = DevLaunchOptions()
        var dataPath = environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
        var folders: [String] = []
        var snapshotPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "-ErsatzDataDir":
                if let value, !value.isEmpty { dataPath = value }
                index += 2
            case "-ErsatzAddFolder":
                if let value, !value.isEmpty { folders.append(value) }
                index += 2
            case "-ErsatzStartFilter":
                if let value, !value.isEmpty { options.startFilter = value.lowercased() }
                index += 2
            case "-ErsatzOpenViewer":
                // Accept a bare flag, or a YES/NO value the way NSUserDefaults arguments look.
                if let value, ["yes", "no", "true", "false", "1", "0"].contains(value.lowercased()) {
                    options.openViewer = ["yes", "true", "1"].contains(value.lowercased())
                    index += 2
                } else {
                    options.openViewer = true
                    index += 1
                }
            case "-ErsatzWindowSize":
                if let value { options.windowSize = WindowSize(parsing: value) }
                index += 2
            case "-ErsatzSnapshot":
                if let value, !value.isEmpty { snapshotPath = value }
                index += 2
            case "-ErsatzSnapshotDelay":
                if let value, let seconds = Double(value), seconds >= 0, seconds <= 600 {
                    options.snapshotDelay = seconds
                }
                index += 2
            default:
                index += 1
            }
        }
        guard let dataPath else { return DevLaunchOptions() }
        options.dataDirectory = absoluteURL(dataPath, isDirectory: true)
        options.addFolders = folders.map { absoluteURL($0, isDirectory: true) }
        options.snapshotURL = snapshotPath.map { absoluteURL($0, isDirectory: false) }
        return options
    }

    private static func absoluteURL(_ path: String, isDirectory: Bool) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: isDirectory).standardizedFileURL
    }
}
