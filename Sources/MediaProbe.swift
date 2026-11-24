import AppKit

enum MediaSource: String, CaseIterable {
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case edge = "com.microsoft.edgemac"
    case quickTime = "com.apple.QuickTimePlayerX"

    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .safari: "Safari"
        case .edge: "Microsoft Edge"
        case .quickTime: "QuickTime Player"
        }
    }
}

enum PlaybackAction: String {
    case toggle, pause, back, forward, returnPlayback
}

struct Media: Decodable {
    let id: String
    let title: String
    let paused: Bool
    let rect: [Double]
    var windowBounds: CGRect? = nil
    var browserWindowID: Int? = nil
    var browserTabIndex: Int? = nil
    var returnedPosition: Bool? = nil

    let mediaURL: String?
    let youtubeID: String?
    let time: Double?
    let duration: Double?
    let volume: Double?
    let seekable: Bool?

    enum CodingKeys: String, CodingKey { case id, title, paused, rect, mediaURL, youtubeID, time, duration, volume, seekable, returnedPosition }

    var directURL: URL? {
        guard let mediaURL, let duration, duration.isFinite, duration > 0,
              let components = URLComponents(string: mediaURL),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    func matchesWindow(_ frame: CGRect) -> Bool {
        guard let bounds = windowBounds else { return false }
        return abs(frame.minX - bounds.minX) <= 2 && abs(frame.minY - bounds.minY) <= 2
            && abs(frame.width - bounds.width) <= 2 && abs(frame.height - bounds.height) <= 2
    }

    var crop: CGRect {
        guard rect.count == 4 else { return .zero }
        return Crop.validated(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]))
    }
}

enum Crop {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func validated(_ rect: CGRect) -> CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return .zero }
        let clipped = rect.intersection(full)
        return clipped.width >= 0.03 && clipped.height >= 0.03 ? clipped : .zero
    }

    static func relative(_ rect: CGRect, to video: CGRect) -> CGRect {
        CGRect(x: (rect.minX - video.minX) / video.width, y: (rect.minY - video.minY) / video.height,
               width: rect.width / video.width, height: rect.height / video.height)
    }

    static func applying(_ relative: CGRect, to video: CGRect) -> CGRect {
        let adjusted = validated(CGRect(x: video.minX + relative.minX * video.width,
                                        y: video.minY + relative.minY * video.height,
                                        width: relative.width * video.width, height: relative.height * video.height))
        return adjusted.isEmpty ? video : adjusted
    }

    static func frameExtent(_ content: CGRect?, scale: CGFloat, in buffer: CGRect) -> CGRect {
        guard let content, !content.isEmpty, scale.isFinite, scale > 0 else { return buffer }
        let visible = CGRect(x: buffer.minX + content.minX * scale,
                             y: buffer.maxY - content.maxY * scale,
                             width: content.width * scale, height: content.height * scale)
            .integral.intersection(buffer)
        return visible.isEmpty ? buffer : visible
    }

    static func raster(_ crop: CGRect, in image: CGImage) -> CGRect {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return CGRect(x: crop.minX * width, y: crop.minY * height,
                      width: crop.width * width, height: crop.height * height)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func pixels(_ crop: CGRect, in image: CGRect) -> CGRect {
        CGRect(x: image.minX + crop.minX * image.width,
               y: image.minY + (1 - crop.maxY) * image.height,
               width: crop.width * image.width, height: crop.height * image.height)
            .integral.intersection(image)
    }
}

final class MediaProbe {
    private let session = "__kadraj_" + UUID().uuidString
    private let javascript = Bundle.main.url(forResource: "Video", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    private let queue = DispatchQueue(label: "kadraj.media")

    func read(_ source: MediaSource, selected: String? = nil, action: PlaybackAction? = nil,
              includePaused: Bool = false, windowID: Int? = nil, windowBounds: CGRect? = nil,
              tabIndex: Int? = nil, returnTime: Double? = nil, returnPlaying: Bool = false) async -> Media? {
        await withCheckedContinuation { continuation in
            run(source, selected: selected, action: action, includePaused: includePaused,
                windowID: windowID, windowBounds: windowBounds, tabIndex: tabIndex,
                returnTime: returnTime, returnPlaying: returnPlaying) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    func run(_ source: MediaSource, selected: String? = nil, action: PlaybackAction? = nil,
             includePaused: Bool = false, windowID: Int? = nil, windowBounds: CGRect? = nil,
             tabIndex: Int? = nil, returnTime: Double? = nil, returnPlaying: Bool = false,
             completion: @escaping (Result<Media?, Error>) -> Void) {
        let script = source == .quickTime
            ? quickTimeScript(id: selected, action: action, includePaused: includePaused)
            : browserScript(source, id: selected, action: action, includePaused: includePaused,
                            windowID: windowID, windowBounds: windowBounds, tabIndex: tabIndex,
                            returnTime: returnTime, returnPlaying: returnPlaying)
        queue.async {
            let result = Result { try Self.execute(script, quickTime: source == .quickTime) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    @MainActor func checkScripts() -> Bool {
        var passed = true
        for source in MediaSource.allCases
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.rawValue) != nil {
            let actions: [PlaybackAction?] = [nil, .toggle, .pause, .back, .forward]
            var scripts = actions.map { action in
                source == .quickTime
                    ? quickTimeScript(id: action == nil ? nil : "123", action: action)
                    : browserScript(source, id: action == nil ? nil : "test:1", action: action,
                                    windowID: action == nil ? nil : 42)
            }
            if source != .quickTime {
                scripts.append(browserScript(source, id: nil, action: nil, includePaused: true,
                                             windowBounds: CGRect(x: 50, y: 60, width: 700, height: 500)))
                scripts.append(browserScript(source, id: "local:1", action: .returnPlayback,
                                             windowID: 42, tabIndex: 3, returnTime: 15, returnPlaying: true))
            }
            var sourcePassed = true
            for script in scripts {
                var error: NSDictionary?
                if NSAppleScript(source: script)?.compileAndReturnError(&error) != true {
                    print("\(source.name): \(error ?? [:])")
                    sourcePassed = false
                }
            }
            if sourcePassed { print("\(source.name): AppleScript sözdizimi geçti.") }
            passed = passed && sourcePassed
        }
        return passed
    }

    private func browserScript(_ source: MediaSource, id: String?, action: PlaybackAction?,
                               includePaused: Bool = false, windowID: Int? = nil, windowBounds: CGRect? = nil,
                               tabIndex: Int? = nil, returnTime: Double? = nil, returnPlaying: Bool = false) -> String {
        let time = returnTime.flatMap { $0.isFinite && $0 >= 0 ? String($0) : nil } ?? ""
        let arguments = [session, id ?? "", action?.rawValue ?? "", source == .safari ? "right" : "left",
                         includePaused ? "1" : "", time, returnPlaying ? "1" : ""]
        let json = (try? JSONEncoder().encode(arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let code = Self.literal("{ const request = " + json + "; " + javascript + " }")
        let activeIndex = source == .safari ? "index of current tab of targetWindow" : "active tab index of targetWindow"
        let command = source == .safari
            ? "set mediaJSON to do JavaScript \(code) in tab pickedIndex of targetWindow"
            : "set mediaJSON to execute tab pickedIndex of targetWindow javascript \(code)"
        let tabSelection: String
        if let tabIndex, tabIndex > 0 {
            tabSelection = """
            set mediaJSON to ""
            if (count of tabs of targetWindow) ≥ \(tabIndex) then
                set pickedIndex to \(tabIndex)
                try
                    \(command)
                end try
            end if
            if mediaJSON is missing value or mediaJSON is "" then
                set pickedIndex to \(activeIndex)
                \(command)
            end if
            """
        } else {
            tabSelection = """
            set pickedIndex to \(activeIndex)
            \(command)
            """
        }
        let windowSelection: String
        if let windowID {
            windowSelection = """
            if not (exists window id \(windowID)) then return ""
            set targetWindow to window id \(windowID)
            """
        } else if let windowBounds {
            let edges = [windowBounds.minX, windowBounds.minY, windowBounds.maxX, windowBounds.maxY]
                .map { String(Int($0.rounded())) }.joined(separator: ", ")
            windowSelection = """
            set targetWindow to missing value
            repeat with candidate in windows
                if (bounds of candidate) = {\(edges)} then
                    set targetWindow to contents of candidate
                    exit repeat
                end if
            end repeat
            if targetWindow is missing value then return ""
            """
        } else {
            windowSelection = "set targetWindow to front window"
        }
        return """
        with timeout of 5 seconds
            tell application id "\(source.rawValue)"
                if (count of windows) = 0 then return ""
                \(windowSelection)
                \(tabSelection)
                if mediaJSON is missing value or mediaJSON is "" then return ""
                set {leftEdge, topEdge, rightEdge, bottomEdge} to bounds of targetWindow
                return ((id of targetWindow) as text) & linefeed & (leftEdge as text) & linefeed & (topEdge as text) & linefeed & (rightEdge as text) & linefeed & (bottomEdge as text) & linefeed & (pickedIndex as text) & linefeed & mediaJSON
            end tell
        end timeout
        """
    }

    private func quickTimeScript(id: String?, action: PlaybackAction?, includePaused: Bool = false) -> String {
        let identityCheck = id.map { "if movieID is not " + Self.literal($0) + " then return \"\"" }
            ?? (includePaused ? "" : "if not playing of movie then return \"\"")
        let command: String
        switch action {
        case .toggle:
            command = """
            if playing of movie then
                pause movie
            else
                play movie
            end if
            """
        case .pause:
            command = "pause movie"
        case .back:
            command = """
            set targetTime to (current time of movie) - 10
            if targetTime < 0 then set targetTime to 0
            set current time of movie to targetTime
            """
        case .forward:
            command = """
            set targetTime to (current time of movie) + 10
            if targetTime > duration of movie then set targetTime to duration of movie
            set current time of movie to targetTime
            """
        case .returnPlayback, nil:
            command = ""
        }
        return """
        with timeout of 5 seconds
            tell application id "\(MediaSource.quickTime.rawValue)"
                if (count of documents) = 0 or (count of windows) = 0 then return ""
                set movie to document 1
                if duration of movie ≤ 0 then return ""
                set movieID to id of window 1 as text
                \(identityCheck)
                \(command)
                return movieID & linefeed & (playing of movie as text) & linefeed & (current time of movie as text) & linefeed & (duration of movie as text) & linefeed & name of movie
            end tell
        end timeout
        """
    }

    private static func literal(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func execute(_ script: String, quickTime: Bool) throws -> Media? {
        let task = Process()
        let output = Pipe()
        let errors = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "Kadraj.Automation", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: detail.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !value.isEmpty else { return nil }
        if quickTime {
            let fields = value.split(separator: "\n", maxSplits: 4)
            guard fields.count == 5 else { return nil }
            let time = Double(fields[2].replacingOccurrences(of: ",", with: "."))
            let duration = Double(fields[3].replacingOccurrences(of: ",", with: "."))
            return Media(id: String(fields[0]), title: String(fields[4]), paused: fields[1] == "false",
                         rect: [0, 0, 1, 1], mediaURL: nil, youtubeID: nil, time: time, duration: duration, volume: nil, seekable: true)
        }
        let fields = value.split(separator: "\n", maxSplits: 6)
        let edges = fields.dropFirst().prefix(4).compactMap { Double($0) }
        guard fields.count == 7, let windowID = Int(fields[0]), edges.count == 4,
              edges.allSatisfy(\.isFinite), edges[2] > edges[0], edges[3] > edges[1] else { return nil }
        var media = try JSONDecoder().decode(Media.self, from: Data(fields[6].utf8))
        media.browserTabIndex = Int(fields[5])
        media.browserWindowID = windowID
        media.windowBounds = CGRect(x: edges[0], y: edges[1],
                                    width: edges[2] - edges[0], height: edges[3] - edges[1])
        return media
    }
}
