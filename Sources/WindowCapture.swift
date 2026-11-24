import AppKit
import CoreImage
import ScreenCaptureKit

final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream!
    private let queue = DispatchQueue(label: "kadraj.frames")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let pendingFrame = DispatchSemaphore(value: 1)
    private let onFrame: (CGImage) -> Void
    private let onStop: (Error) -> Void
    private var crop: CGRect
    private var lastFrame: CIImage?
    private var suspended = false

    init(window: SCWindow, crop: CGRect,
         onFrame: @escaping (CGImage) -> Void, onStop: @escaping (Error) -> Void) {
        self.crop = crop
        self.onFrame = onFrame
        self.onStop = onStop
        let filter = SCContentFilter(desktopIndependentWindow: window)
        super.init()
        stream = SCStream(filter: filter, configuration: Self.configuration(for: filter), delegate: self)
    }

    static func snapshot(of window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: filter))
    }

    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(2, Int((size.width * scale).rounded(.up)))
        config.height = max(2, Int((size.height * scale).rounded(.up)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        config.scalesToFit = false
        return config
    }

    func start() async throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
    }

    func suspend() {
        queue.async {
            self.suspended = true
            self.lastFrame = nil
        }
    }

    func setCrop(_ crop: CGRect) {
        queue.async {
            if self.suspended {
                self.crop = crop
                self.suspended = false
                return
            }
            guard self.crop != crop else { return }
            self.crop = crop
            if let frame = self.lastFrame { self.render(frame) }
        }
    }

    func snapshot(_ completion: @escaping (CGImage?) -> Void) {
        queue.async {
            let image = self.lastFrame.flatMap { self.context.createCGImage($0, from: $0.extent) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onStop(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !suspended, type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let metadata = attachments.first,
              let code = metadata[.status] as? Int,
              SCFrameStatus(rawValue: code) == .complete,
              let frame = buffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: frame)
        let content = CGRect(dictionaryRepresentation: metadata[.contentRect] as? NSDictionary ?? [:])
        let scale = (metadata[.scaleFactor] as? NSNumber)?.doubleValue ?? 1
        let extent = Crop.frameExtent(content, scale: scale, in: image.extent)
        let visible = image.cropped(to: extent)
        lastFrame = visible
        render(visible)
    }

    private func render(_ image: CIImage) {
        guard pendingFrame.wait(timeout: .now()) == .success else { return }
        guard let result = context.createCGImage(image, from: Crop.pixels(crop, in: image.extent)) else {
            pendingFrame.signal()
            return
        }
        DispatchQueue.main.async {
            self.onFrame(result)
            self.pendingFrame.signal()
        }
    }
}
