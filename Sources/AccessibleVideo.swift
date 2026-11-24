import AppKit
import ApplicationServices

struct AccessibleVideo {
    let pid: pid_t
    let window: AXUIElement
    let area: AXUIElement?
    let element: AXUIElement
    let page: URL?
    let windowFrame: CGRect
    let crop: CGRect
    let paused: Bool?

    var id: String { "\(pid):\(CFHash(element))" }

    func matchesWindow(_ frame: CGRect) -> Bool {
        abs(frame.minX - windowFrame.minX) <= 3 && abs(frame.minY - windowFrame.minY) <= 3
            && abs(frame.width - windowFrame.width) <= 3 && abs(frame.height - windowFrame.height) <= 3
    }
}

final class AccessibleVideoProbe {
    private let queue = DispatchQueue(label: "kadraj.accessibility", qos: .userInitiated)

    var trusted: Bool { AXIsProcessTrusted() }

    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func discover(pid: pid_t, includePaused: Bool, completion: @escaping (AccessibleVideo?) -> Void) {
        queue.async {
            let match = Self.discover(pid: pid, includePaused: includePaused)
            DispatchQueue.main.async { completion(match) }
        }
    }

    func refresh(_ selected: AccessibleVideo, toggle: Bool = false,
                 completion: @escaping (AccessibleVideo?) -> Void) {
        queue.async {
            let current = Self.refresh(selected, toggle: toggle)
            DispatchQueue.main.async { completion(current) }
        }
    }

    private static func discover(pid: pid_t, includePaused: Bool) -> AccessibleVideo? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        guard let window: AXUIElement = value(app, kAXFocusedWindowAttribute),
              let frame = bounds(window), !frame.isEmpty else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
        var stack: [(element: AXUIElement, area: AXUIElement?)] = [(window, nil)]

        while let node = stack.popLast(), ContinuousClock.now < deadline {
            let role: String? = value(node.element, kAXRoleAttribute)
            let area = role == "AXWebArea" ? node.element : node.area
            let subrole: String? = value(node.element, kAXSubroleAttribute)
            let nativeVideo = role == "AXVideo" || subrole == "AXVideo"
            let label = (value(node.element, kAXDescriptionAttribute) as String?
                         ?? value(node.element, kAXTitleAttribute) as String? ?? "").lowercased()
            if nativeVideo || ["video player", "video oynatıcı", "video oynatıcısı"].contains(label) {
                let state = playButton(in: node.element)?.paused
                if (state == false || (includePaused && (nativeVideo || state != nil))),
                   let crop = crop(element: node.element, area: area, in: frame), !crop.isEmpty {
                    return AccessibleVideo(pid: pid, window: window, area: area, element: node.element,
                                           page: area.flatMap { value($0, kAXURLAttribute) },
                                           windowFrame: frame, crop: crop, paused: state)
                }
            }
            if ["AXButton", "AXStaticText", "AXImage", "AXSlider", "AXTextField"].contains(role) { continue }
            for child in children(node.element, limit: 90).reversed() {
                stack.append((child, area))
            }
        }
        return nil
    }

    private static func refresh(_ video: AccessibleVideo, toggle: Bool) -> AccessibleVideo? {
        guard AXIsProcessTrusted(), let frame = bounds(video.window) else { return nil }
        if let area = video.area {
            let currentURL: URL? = value(area, kAXURLAttribute)
            guard currentURL == video.page, belongsToActivePage(video.element, area: area, window: video.window) else { return nil }
        }
        // An invalid or scrolled-out element leaves the last verified frame on screen.
        guard let region = crop(element: video.element, area: video.area, in: frame) else { return nil }
        let button = playButton(in: video.element)
        var paused = button?.paused
        if toggle, let button, AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success {
            paused = !button.paused
        }
        return AccessibleVideo(pid: video.pid, window: video.window, area: video.area, element: video.element,
                               page: video.page, windowFrame: frame, crop: region, paused: paused)
    }

    private static func belongsToActivePage(_ element: AXUIElement, area: AXUIElement, window: AXUIElement) -> Bool {
        var ancestor = element
        var foundArea = false
        for _ in 0..<35 {
            if CFEqual(ancestor, area) { foundArea = true }
            if CFEqual(ancestor, window) { return foundArea }
            guard let parent: AXUIElement = value(ancestor, kAXParentAttribute) else { return false }
            // Safari keeps selection state on the scroll area's child list.
            if (value(ancestor, kAXRoleAttribute) as String?) == "AXWebArea",
               !children(parent, limit: 90).contains(where: { CFEqual($0, ancestor) }) {
                return false
            }
            ancestor = parent
        }
        return false
    }

    private static func playButton(in root: AXUIElement) -> (element: AXUIElement, paused: Bool)? {
        var stack = [root]
        for _ in 0..<35 {
            guard let element = stack.popLast() else { break }
            let role: String? = value(element, kAXRoleAttribute)
            if role == "AXButton" {
                for label in [value(element, kAXTitleAttribute) as String?,
                              value(element, kAXDescriptionAttribute) as String?].compactMap({ $0?.lowercased() }) {
                    if ["pause", "duraklat", "pause video", "videoyu duraklat"].contains(label) { return (element, false) }
                    if ["play", "oynat", "play video", "videoyu oynat"].contains(label) { return (element, true) }
                }
            } else {
                stack.append(contentsOf: children(element, limit: 35).reversed())
            }
        }
        return nil
    }

    private static func crop(element: AXUIElement, area: AXUIElement?, in frame: CGRect) -> CGRect? {
        guard let elementFrame = bounds(element) else { return nil }
        var visible = frame.intersection(elementFrame)
        if let area, let page = bounds(area) { visible = visible.intersection(page) }
        guard !visible.isNull, visible.width >= 100, visible.height >= 60 else { return .zero }
        return Crop.validated(CGRect(x: (visible.minX - frame.minX) / frame.width,
                                     y: (visible.minY - frame.minY) / frame.height,
                                     width: visible.width / frame.width, height: visible.height / frame.height))
    }

    private static func value<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func bounds(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions),
              [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func children(_ element: AXUIElement, limit: Int) -> [AXUIElement] {
        var count = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0 else { return [] }
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(limit, count), &children) == .success
        else { return [] }
        return children as? [AXUIElement] ?? []
    }
}
