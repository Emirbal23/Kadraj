import AVFoundation
import Foundation
import ImageIO
import Network

struct SafariVideo: Decodable, Equatable {
    let id: UUID
    let title: String
    let supportsHandback: Bool?
    let mirrorOnly: Bool?
    let canMirror: Bool?
    let youtubeID: String?
    let protocolVersion: Int?
}

struct SafariMedia: Decodable {
    let url: URL?
    let time: Double
    let duration: Double?
    let volume: Double
    let paused: Bool
    let seekable: Bool?
    let mirror: SafariMirrorGeometry?

    var playableURL: URL? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        return url
    }
}

struct SafariMirrorGeometry: Decodable {
    private let window: [Double]
    private let crop: [Double]
    let title: String

    var region: CGRect {
        guard crop.count == 4, crop.allSatisfy({ $0.isFinite && (0...1.002).contains($0) }) else { return .zero }
        return Crop.validated(CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3]))
    }

    func matches(frame: CGRect, title windowTitle: String?) -> Bool {
        guard window.count == 4, window.allSatisfy({ $0.isFinite && abs($0) < 100_000 }),
              window[2] >= 100, window[3] >= 60 else { return false }
        let edges = [frame.minX, frame.minY, frame.width, frame.height]
        guard zip(edges, window).allSatisfy({ abs($0 - $1) <= 5 }) else { return false }
        if let windowTitle, !title.isEmpty {
            return windowTitle == title || windowTitle.hasSuffix(" — " + title)
                || (title.count == 230 && windowTitle.contains(title))
        }
        return true
    }
}

enum SafariBridgeCommand: String, Encodable {
    case describe, claim, returnPlayback, toggle, back, forward, startFrames
}

@MainActor
final class SafariBridge {
    static let port: UInt16 = 49196

    private let code: String
    var didOffer: ((SafariVideo, Bool) -> Void)?
    var didWithdraw: ((UUID) -> Void)?
    var didLoseSource: ((UUID) -> Void)?
    var didReceiveFrame: ((UUID, SafariMedia, CGImage?) -> Void)?
    var frameVideo: UUID? {
        didSet {
            if let oldValue, oldValue != frameVideo { retiredFrameVideo = oldValue }
            frameGeneration = UUID()
            frameContactAt = SuspendingClock.now
            if frameVideo == nil { frameSize = nil }
        }
    }
    var frameSize: [Int]?
    var mirrorVideo: UUID?
    private(set) var frameContactAt = SuspendingClock.now
    private var frameGeneration = UUID()
    private var retiredFrameVideo: UUID?
    private var pairingTicket: (value: String, expires: ContinuousClock.Instant)?
    private var listener: NWListener?
    private var pending: [UUID: Waiter] = [:]
    private var owned: Set<UUID> = []

    private struct Command: Encodable {
        let id: UUID
        let kind: SafariBridgeCommand
        let time: Double?
        let play: Bool?
    }

    private struct Waiter {
        let command: Command
        var delivered = false
        let continuation: CheckedContinuation<Reply?, Never>
    }

    struct Reply: Decodable {
        let id: UUID
        let success: Bool
        let failure: String?
        let media: SafariMedia?
        let claimed: Bool?
        let positioned: Bool?
    }

    private struct Request: Decodable {
        let token: String?
        let ticket: String?
        let operation: String
        let video: SafariVideo?
        let open: Bool?
        let available: Bool?
        let reply: Reply?
        let image: String?
        let media: SafariMedia?
    }

    private struct Response: Encodable {
        let ok: Bool
        let command: Command?
        let owned: Bool?
        let streaming: Bool?
        let frameSize: [Int]?
        let dismissed: Bool?
    }

    init(code: String? = nil) {
        let defaults = UserDefaults.standard
        if let code {
            self.code = code
        } else {
            let key = "safariBridgeCode"
            let saved = defaults.string(forKey: key) ?? UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            self.code = saved
            defaults.set(saved, forKey: key)
        }
    }

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let queue = DispatchQueue(label: "kadraj.safari.local")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let server = try? NWListener(using: parameters) else { return }
        server.newConnectionHandler = { [weak self] connection in
            HTTPPeer(connection, queue: queue).read { data, frames in
                await self?.handle(data, frames: frames) ?? (503, Data())
            }
        }
        server.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.async { self?.listener = nil }
            }
        }
        listener = server
        server.start(queue: queue)
    }

    func makePairingURL() -> URL? {
        guard listener?.state == .ready else { return nil }
        let ticket = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        pairingTicket = (ticket, ContinuousClock.now.advanced(by: .seconds(120)))
        return URL(string: "http://127.0.0.1:\(Self.port)/connect#\(ticket)")
    }

    func request(_ command: SafariBridgeCommand, video: UUID, time: Double? = nil, play: Bool? = nil) async -> Reply? {
        guard pending[video] == nil else { return nil }
        return await withCheckedContinuation { continuation in
            let command = Command(id: UUID(), kind: command, time: time, play: play)
            pending[video] = Waiter(command: command, continuation: continuation)
            Task {
                let timeout = switch command.kind {
                case .returnPlayback: 8
                case .startFrames: 7
                default: 5
                }
                try? await Task.sleep(for: .seconds(timeout))
                guard pending[video]?.command.id == command.id else { return }
                pending.removeValue(forKey: video)?.continuation.resume(returning: nil)
            }
        }
    }

    func transfer(_ video: UUID, while isCurrent: () -> Bool) async -> (player: AVPlayer, source: SafariMedia)? {
        guard let initial = await request(.describe, video: video)?.media, let url = initial.playableURL,
              isCurrent(),
              let player = await NativePlayback.prepare(url, allowLive: initial.duration == nil, while: isCurrent),
              isCurrent(),
              let current = await request(.describe, video: video)?.media, current.playableURL == url,
              isCurrent() else { return nil }
        if current.duration != nil, current.time > 0.05,
           !(await NativePlayback.seek(player, to: current.time)) { return nil }
        guard isCurrent() else { return nil }
        let claim = await request(.claim, video: video)
        guard claim?.success == true, claim?.claimed == true else { return nil }
        guard isCurrent() else {
            _ = await returnPlayback(video, at: current.time, play: !current.paused)
            return nil
        }
        return (player, current)
    }

    func returnPlayback(_ video: UUID, at time: Double?, play: Bool) async -> Bool {
        guard owned.contains(video) else { return false }
        let position = time.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let reply = await request(.returnPlayback, video: video, time: position, play: play)
        owned.remove(video)
        return reply?.success == true && (position == nil || reply?.positioned == true)
    }

    func abandonFrames() {
        frameVideo = nil
        retiredFrameVideo = nil
    }

    private func handle(_ data: Data, frames: Bool) async -> (Int, Data) {
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else {
            return response(400, ok: false)
        }
        if !frames && request.operation == "pair" {
            guard let pairingTicket, request.ticket == pairingTicket.value, ContinuousClock.now < pairingTicket.expires else {
                return response(403, ok: false)
            }
            self.pairingTicket = nil
            return (200, (try? JSONEncoder().encode(["token": code])) ?? Data())
        }
        guard request.token == code else { return response(403, ok: false) }
        if frames {
            guard let video = request.video else { return response(400, ok: false) }
            guard video.id == frameVideo else { return retiredFrameResponse(video.id) }
            let generation = frameGeneration
            frameContactAt = SuspendingClock.now
            if request.operation == "frameWait" {
                // Safari throttles timers when a background video has been paused.
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while generation == frameGeneration, pending[video.id]?.delivered != false, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard generation == frameGeneration else { return retiredFrameResponse(video.id) }
                return poll(video.id)
            }
            guard request.operation == "frame", let media = request.media else { return response(400, ok: false) }
            let image: CGImage?
            if let encoded = request.image {
                image = await Task.detached(priority: .userInitiated) { Self.decodeFrame(encoded) }.value
                guard generation == frameGeneration else { return retiredFrameResponse(video.id) }
                guard image != nil else { return response(400, ok: false) }
            } else { image = nil }
            didReceiveFrame?(video.id, media, image)
            return poll(video.id)
        }
        if request.operation == "ping" { return response(200, ok: true) }
        guard let video = request.video, video.title.count <= 250 else { return response(400, ok: false) }
        switch request.operation {
        case "poll":
            if video.id == frameVideo { frameContactAt = SuspendingClock.now }
            if request.open == true || request.available == true { didOffer?(video, request.open == true) }
            return poll(video.id)
        case "withdraw":
            didWithdraw?(video.id)
            return response(200, ok: true)
        case "lost":
            owned.remove(video.id)
            pending.removeValue(forKey: video.id)?.continuation.resume(returning: nil)
            didWithdraw?(video.id)
            didLoseSource?(video.id)
            return response(200, ok: true)
        case "reply":
            guard let reply = request.reply, let waiter = pending[video.id],
                  waiter.delivered, waiter.command.id == reply.id else { return response(409, ok: false) }
            pending.removeValue(forKey: video.id)
            if waiter.command.kind == .claim, reply.success, reply.claimed == true { owned.insert(video.id) }
            if waiter.command.kind == .returnPlayback { owned.remove(video.id) }
            waiter.continuation.resume(returning: reply)
            if waiter.command.kind == .startFrames {
                return response(200, ok: true, streaming: frameVideo == video.id)
            }
            return response(200, ok: true)
        default:
            return response(400, ok: false)
        }
    }

    private func poll(_ id: UUID) -> (Int, Data) {
        var command: Command?
        if var waiter = pending[id], !waiter.delivered {
            waiter.delivered = true
            pending[id] = waiter
            command = waiter.command
        }
        let streaming = frameVideo == id || mirrorVideo == id
        return response(200, ok: true, command: command, owned: owned.contains(id),
                        streaming: streaming, dismissed: streaming ? nil : retiredFrameVideo == id)
    }

    private func retiredFrameResponse(_ id: UUID) -> (Int, Data) {
        response(409, ok: false, streaming: false, dismissed: retiredFrameVideo == id)
    }

    nonisolated private static func decodeFrame(_ encoded: String) -> CGImage? {
        guard encoded.utf8.count <= 360_000, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let size = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = size[kCGImagePropertyPixelWidth] as? Int, (1...1920).contains(width),
              let height = size[kCGImagePropertyPixelHeight] as? Int, (1...1080).contains(height) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private func response(_ code: Int, ok: Bool, command: Command? = nil, owned: Bool? = nil,
                          streaming: Bool? = nil, dismissed: Bool? = nil) -> (Int, Data) {
        (code, (try? JSONEncoder().encode(Response(ok: ok, command: command, owned: owned,
                                                  streaming: streaming,
                                                  frameSize: streaming == true ? frameSize : nil,
                                                  dismissed: dismissed))) ?? Data())
    }
}

// The receive buffer and request timeout are confined to the Network.framework queue.
private final class HTTPPeer: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var timeout: DispatchWorkItem?
    private static let separator = Data([13, 10, 13, 10])
    private static let limit = 376_000
    private static let pairingPage = Data("""
    <!doctype html><html lang="tr"><meta charset="utf-8"><title>Kadraj · Safari bağlantısı</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>:root{color-scheme:light dark}body{font:16px system-ui;margin:12vh auto;padding:0 24px;max-width:480px;line-height:1.6}</style>
    <h1>Kadraj</h1>
    <p id="pair-status" role="status">Safari bağlantısı bekleniyor.</p>
    <p id="pair-help">Safari erişim isterse araç çubuğundaki Kadraj simgesinden izin verin.</p></html>
    """.utf8)

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func read(_ handle: @escaping @MainActor (Data, Bool) async -> (Int, Data)) {
        connection.start(queue: queue)
        readRequest(handle)
    }

    private func readRequest(_ handle: @escaping @MainActor (Data, Bool) async -> (Int, Data)) {
        let timeout = DispatchWorkItem { [weak connection] in connection?.cancel() }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + 4, execute: timeout)
        receive(handle)
    }

    private func receive(_ handle: @escaping @MainActor (Data, Bool) async -> (Int, Data)) {
        guard buffer.count <= Self.limit else { send(status: 400); return }
        if let split = buffer.range(of: Self.separator) {
            guard split.lowerBound - buffer.startIndex < 8192,
                  let header = String(data: buffer[..<split.lowerBound], encoding: .utf8) else {
                send(status: 400)
                return
            }
            if header.hasPrefix("GET /connect HTTP/1.1\r\n") {
                send(status: 200, body: Self.pairingPage, html: true)
                return
            }
            guard let (length, frames, reusable) = bodyLength(header) else { send(status: 400); return }
            let end = split.upperBound + length
            if buffer.endIndex >= end {
                let body = Data(buffer[split.upperBound..<end])
                buffer.removeSubrange(..<end)
                Task { @MainActor in
                    let (status, response) = await handle(body, frames)
                    self.queue.async {
                        if reusable && status == 200 {
                            self.send(status: status, body: response) { self.readRequest(handle) }
                        } else {
                            self.send(status: status, body: response)
                        }
                    }
                }
                return
            }
        } else if buffer.count >= 8192 {
            send(status: 400)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, ended, error in
            if let data { buffer.append(data) }
            if error != nil || ended {
                // A final receive can still contain the body of a request with Connection: close.
                if let data, !data.isEmpty, error == nil { receive(handle) }
                else { connection.cancel() }
            } else {
                receive(handle)
            }
        }
    }

    private func bodyLength(_ header: String) -> (Int, Bool, Bool)? {
        let lines = header.components(separatedBy: "\r\n")
        let frames = lines.first == "POST /frames HTTP/1.1"
        guard frames || lines.first == "POST /kadraj HTTP/1.1" else { return nil }
        var length: Int?
        var reusable = frames
        for line in lines.dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard field.count == 2 else { return nil }
            switch field[0].lowercased() {
            case "content-length":
                guard length == nil, let value = Int(field[1].trimmingCharacters(in: .whitespaces)),
                      value > 0, value <= (frames ? 368_000 : 16_000) else { return nil }
                length = value
            case "transfer-encoding":
                return nil
            case "connection":
                if field[1].split(separator: ",").contains(where: {
                    $0.trimmingCharacters(in: .whitespaces).lowercased() == "close"
                }) { reusable = false }
            default:
                break
            }
        }
        return length.map { ($0, frames, reusable) }
    }

    private func send(status: Int, body: Data = Data(), html: Bool = false, then next: (() -> Void)? = nil) {
        timeout?.cancel()
        timeout = nil
        let reason = status == 200 ? "OK" : "Error"
        let connectionHeader = next == nil ? "close" : "keep-alive"
        let type = html ? "text/html; charset=utf-8" : "application/json"
        let policy = html ? "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'\r\n" : ""
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n\(policy)Connection: \(connectionHeader)\r\n\r\n"
        var bytes = Data(header.utf8)
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { [connection] error in
            if error == nil, let next { next() } else { connection.cancel() }
        })
    }
}
