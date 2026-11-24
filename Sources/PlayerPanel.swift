import AppKit
import AVFoundation

final class PlayerPanel: NSPanel {
    private let videoView = VideoSurface()
    private let controls = NSStackView()
    private let playButton: NSButton
    private let playbackButtons: [NSButton]
    private let cropButton: NSButton
    private let pinButton: NSButton
    private let aspectButton: NSButton
    private let sourceStatus = NSTextField(labelWithString: "")
    private let commandHint = NSTextField(labelWithString: "⌘  Kontroller için basılı tutun")
    private let timeline = NSTextField(labelWithString: "")
    private var webPlayer: NSView?
    private var webPlayerBottom: NSLayoutConstraint?
    private var resizing = false
    private var aspectLocked = false
    private var lastPlaybackState: (paused: Bool?, seekable: Bool)?
    private var timelineSample: (second: Double?, duration: Double?)?
    var hoverTransparency = 73
    var showsCommandHint = true

    override var canBecomeKey: Bool { true }

    init() {
        playButton = Self.button("play.fill", "Oynat / Duraklat", #selector(AppController.togglePlayback))
        pinButton = Self.button("pin.fill", "Son kareyi sabitle", #selector(AppController.togglePictureFreeze))
        aspectButton = Self.button("lock.open", "En-boy oranını kilitle", #selector(AppController.toggleAspectLock))
        cropButton = Self.button("crop", "Video bölgesini seç", #selector(AppController.selectCrop))
        playbackButtons = [
            Self.button("gobackward.10", "10 saniye geri sar", #selector(AppController.seekBack)),
            playButton,
            Self.button("goforward.10", "10 saniye ileri sar", #selector(AppController.seekForward))
        ]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 236),
                   styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Kadraj"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 395, height: 170)
        isOpaque = false
        backgroundColor = .clear
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let container = NSView()
        contentView = container
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.layer?.contentsGravity = .resizeAspect
        videoView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)
        sourceStatus.translatesAutoresizingMaskIntoConstraints = false
        sourceStatus.drawsBackground = true
        sourceStatus.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        sourceStatus.textColor = .white
        sourceStatus.font = .systemFont(ofSize: 11, weight: .medium)
        sourceStatus.isHidden = true
        container.addSubview(sourceStatus)

        let hintBackground = NSView()
        hintBackground.wantsLayer = true
        hintBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        hintBackground.layer?.cornerRadius = 8
        hintBackground.translatesAutoresizingMaskIntoConstraints = false
        hintBackground.isHidden = true
        container.addSubview(hintBackground)
        commandHint.font = .systemFont(ofSize: 12, weight: .medium)
        commandHint.textColor = .white
        commandHint.setAccessibilityLabel("Kontroller için Komut tuşunu basılı tutun")
        commandHint.translatesAutoresizingMaskIntoConstraints = false
        hintBackground.addSubview(commandHint)

        let chrome = NSVisualEffectView()
        chrome.material = .hudWindow
        chrome.state = .active
        chrome.blendingMode = .withinWindow
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 8
        chrome.appearance = NSAppearance(named: .darkAqua)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.isHidden = true
        container.addSubview(chrome)
        controls.orientation = .horizontal
        controls.spacing = 4
        for button in playbackButtons + [cropButton, pinButton] { controls.addArrangedSubview(button) }
        timeline.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeline.textColor = .white
        timeline.isHidden = true
        timeline.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.setCustomSpacing(7, after: pinButton)
        controls.addArrangedSubview(timeline)
        controls.setCustomSpacing(7, after: timeline)
        controls.addArrangedSubview(aspectButton)
        controls.addArrangedSubview(Self.button("eye.slash", "Kadrajı gizle", #selector(AppController.toggleVisibility)))
        controls.addArrangedSubview(Self.button("xmark", "Kadrajı kapat", #selector(AppController.closePlayer)))
        controls.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(controls)

        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sourceStatus.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            sourceStatus.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            hintBackground.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hintBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            commandHint.leadingAnchor.constraint(equalTo: hintBackground.leadingAnchor, constant: 10),
            commandHint.trailingAnchor.constraint(equalTo: hintBackground.trailingAnchor, constant: -10),
            commandHint.topAnchor.constraint(equalTo: hintBackground.topAnchor, constant: 6),
            commandHint.bottomAnchor.constraint(equalTo: hintBackground.bottomAnchor, constant: -6),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
            chrome.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            controls.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -6),
            controls.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 4),
            controls.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -4)
        ])
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 26, y: visible.minY + 26))
        }
    }

    private static func button(_ symbol: String, _ title: String, _ selector: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: selector)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.isBordered = false
        button.contentTintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 29),
                                     button.heightAnchor.constraint(equalToConstant: 30)])
        return button
    }

    func bind(to owner: AppController) {
        for case let button as NSButton in controls.arrangedSubviews { button.target = owner }
    }

    func showFrame(_ image: CGImage?) {
        videoView.layer?.contents = image
    }

    func showNativePlayer(_ player: AVPlayer?) {
        videoView.playerLayer.player = player
        videoView.playerLayer.isHidden = player == nil
        cropButton.isHidden = player != nil
        pinButton.isHidden = player != nil
    }

    func showWebPlayer(_ view: NSView?) {
        webPlayer?.removeFromSuperview()
        webPlayerBottom = nil
        webPlayer = view
        minSize.height = view == nil ? 170 : 250
        guard let view else { return }
        if frame.height < minSize.height {
            var newFrame = frame
            newFrame.size.height = minSize.height
            setFrame(newFrame, display: true)
        }
        cropButton.isHidden = true
        pinButton.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        videoView.addSubview(view)
        let bottom = view.bottomAnchor.constraint(equalTo: videoView.bottomAnchor)
        webPlayerBottom = bottom
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: videoView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: videoView.trailingAnchor),
            view.topAnchor.constraint(equalTo: videoView.topAnchor),
            bottom
        ])
    }

    func hideCropControl() { cropButton.isHidden = true }

    func toggleAspectLock() {
        aspectLocked.toggle()
        if aspectLocked { aspectRatio = frame.size }
        else { resizeIncrements = NSSize(width: 1, height: 1) }
        let title = aspectLocked ? "En-boy oranı kilidini aç" : "En-boy oranını kilitle"
        aspectButton.image = NSImage(systemSymbolName: aspectLocked ? "lock.fill" : "lock.open", accessibilityDescription: title)
        aspectButton.toolTip = title
        aspectButton.setAccessibilityLabel(title)
    }

    func showSourceStatus(_ message: String?, frozen: Bool = false) {
        let text = message.map { "  " + $0 + "  " } ?? ""
        if sourceStatus.stringValue != text { sourceStatus.stringValue = text }
        if sourceStatus.isHidden != (message == nil) { sourceStatus.isHidden = message == nil }
        if frozen { cropButton.isHidden = true }
    }

    func setPicturePin(_ pinned: Bool) {
        let title = pinned ? "Sabitlemeyi kaldır" : "Son kareyi sabitle"
        if pinned { pinButton.isHidden = false }
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.slash.fill" : "pin.fill", accessibilityDescription: title)
        pinButton.toolTip = title
        pinButton.setAccessibilityLabel(title)
    }

    func playbackState(_ paused: Bool?, seekable: Bool = false) {
        if let lastPlaybackState, lastPlaybackState.paused == paused, lastPlaybackState.seekable == seekable { return }
        lastPlaybackState = (paused, seekable)
        playButton.isHidden = paused == nil
        playbackButtons[0].isHidden = !seekable || paused == nil
        playbackButtons[2].isHidden = !seekable || paused == nil
        let paused = paused ?? true
        let name = paused ? "Oynat" : "Duraklat"
        playButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                   accessibilityDescription: name)
        playButton.toolTip = name
        playButton.setAccessibilityLabel(name)
    }

    func showTime(_ elapsed: Double?, duration: Double?) {
        let second = elapsed?.rounded(.down)
        if let timelineSample, timelineSample.second == second, timelineSample.duration == duration { return }
        timelineSample = (second, duration)
        guard let text = Self.timeLabel(elapsed, duration: duration) else {
            timeline.isHidden = true
            return
        }
        timeline.isHidden = false
        if timeline.stringValue != text {
            timeline.stringValue = text
            timeline.setAccessibilityLabel("Oynatma süresi " + text)
        }
    }

    static func timeLabel(_ elapsed: Double?, duration: Double?) -> String? {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return nil }
        guard let duration, duration.isFinite, duration > 0 else { return "Canlı" }
        let withHours = duration >= 3600
        func format(_ seconds: Double) -> String {
            let whole = Int(min(seconds, 9_999_999))
            let minutes = whole / 60
            let seconds = String(format: "%02d", whole % 60)
            return withHours ? "\(minutes / 60):" + String(format: "%02d", minutes % 60) + ":" + seconds
                : "\(minutes):" + seconds
        }
        return format(min(elapsed, duration)) + " / " + format(duration)
    }

    func updateInteraction(mouse: NSPoint = NSEvent.mouseLocation,
                           modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
                           buttons: Int = NSEvent.pressedMouseButtons) {
        guard isVisible else { return }
        let hovered = frame.contains(mouse)
        let command = modifiers.contains(.command)
        resizing = buttons != 0 && (resizing || (hovered && command))
        let editing = (hovered && command) || resizing
        let transparent = hovered && !editing && hoverTransparency > 0
        let opacity: CGFloat = transparent ? CGFloat(100 - hoverTransparency) / 100 : 1
        videoView.alphaValue = opacity
        sourceStatus.alphaValue = opacity
        let showHint = transparent && showsCommandHint
        commandHint.superview?.isHidden = !showHint
        webPlayerBottom?.constant = editing || showHint ? -47 : 0
        ignoresMouseEvents = !editing
        controls.superview?.isHidden = !editing
    }

    func checkInteraction() {
        orderFrontRegardless()
        toggleAspectLock()
        assert(aspectLocked && aspectRatio == frame.size)
        toggleAspectLock()
        assert(!aspectLocked && resizeIncrements == NSSize(width: 1, height: 1))
        let inside = CGPoint(x: frame.midX, y: frame.midY)
        let outside = CGPoint(x: frame.maxX + 1, y: frame.midY)
        updateInteraction(mouse: inside, modifiers: [], buttons: 0)
        assert(videoView.alphaValue == 0.27 && ignoresMouseEvents && commandHint.superview?.isHidden == false)
        hoverTransparency = 100
        updateInteraction(mouse: inside, modifiers: [], buttons: 0)
        assert(videoView.alphaValue == 0 && ignoresMouseEvents && commandHint.superview?.isHidden == false)
        showsCommandHint = false
        updateInteraction(mouse: inside, modifiers: [], buttons: 0)
        assert(commandHint.superview?.isHidden == true)
        showsCommandHint = true
        updateInteraction(mouse: inside, modifiers: [.command], buttons: 0)
        assert(videoView.alphaValue == 1 && !ignoresMouseEvents && commandHint.superview?.isHidden == true)
        updateInteraction(mouse: inside, modifiers: [.command], buttons: 1)
        updateInteraction(mouse: outside, modifiers: [], buttons: 1)
        assert(!ignoresMouseEvents)
        updateInteraction(mouse: outside, modifiers: [], buttons: 0)
        assert(videoView.alphaValue == 1 && ignoresMouseEvents)
        orderOut(nil)
    }
}

private final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()

    override func layout() {
        super.layout()
        if playerLayer.superlayer == nil {
            playerLayer.isHidden = playerLayer.player == nil
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

final class CropView: NSView {
    private let image: NSImage
    private var anchor: CGPoint?
    private var selection: CGRect = .zero
    var onSelection: ((CGRect) -> Void)?

    init(image: CGImage) {
        self.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        super.init(frame: .zero)
        setAccessibilityLabel("Video bölgesini seçmek için görüntü üzerinde sürükleyin")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        if selection.isEmpty { return }
        NSColor.black.withAlphaComponent(0.55).setFill()
        let mask = NSBezierPath(rect: bounds)
        mask.appendRect(selection)
        mask.windingRule = .evenOdd
        mask.fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        anchor = nil
        let crop = Crop.validated(CGRect(x: selection.minX / bounds.width,
                                       y: 1 - selection.maxY / bounds.height,
                                       width: selection.width / bounds.width,
                                       height: selection.height / bounds.height))
        if !crop.isEmpty { onSelection?(crop) }
    }
}
