import CoreGraphics
import Foundation

struct WindowStamp {
    let title: String?
    let frame: CGRect

    static func read(_ id: CGWindowID) -> WindowStamp? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?
            .first(where: { $0[kCGWindowNumber as String] as? CGWindowID == id }),
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: dictionary) else { return nil }
        return WindowStamp(title: info[kCGWindowName as String] as? String, frame: frame)
    }

    func sameContent(as other: WindowStamp) -> Bool {
        title == other.title && frame.size == other.frame.size
    }
}
