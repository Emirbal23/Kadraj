import AppKit
import AVFoundation
import MediaPlayer
import SafariServices
import ScreenCaptureKit

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private static let safariExtensionID = "app.kadraj.macos.Extension"
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let player = PlayerPanel()
    private let shortcuts = PlayerShortcuts()
    private var hiddenByUser = false
    private var terminating = false
    private var handbacks: [UUID: Task<Void, Never>] = [:]
    private var handbackFailed = false
    private let probe = MediaProbe()
    private let safariBridge = SafariBridge()
    private var extensionOfferID: UUID?
    private var safariMirror: UUID? {
        didSet { safariBridge.mirrorVideo = safariMirror }
    }
    private var safariMirrorFreshUntil = Date.distantPast
    private var safariMirrorRevision = 0
    private var safariMirrorControl: SafariBridgeCommand?
    private var safariFrameAt = Date.distantPast
    private var safariFramePaused = false
    private var lastExtensionVideo = Date.distantPast
    private var bridgeOpening: UUID?
    private var safariOpening: (id: UUID, task: Task<Void, Never>)?
    private let accessibility = AccessibleVideoProbe()
    private enum NativeSource {
        case safariExtension(UUID)
        case browser(MediaSource, Media)
    }
    private enum SelectionMode { case video, window, still }
    private enum Offer {
        case browser(MediaSource, Media)
        case accessibility(MediaSource, AccessibleVideo)
        case safariExtension(SafariVideo)

        var source: MediaSource {
            switch self {
            case .browser(let source, _), .accessibility(let source, _): source
            case .safariExtension: .safari
            }
        }
    }
    private var trackedAccessible: AccessibleVideo?
    private var acceptedStamp: WindowStamp?
    private var sourceWindowID: CGWindowID?
    private var sourceProcessID: pid_t?
    private var lastAXOffer: String?
    private var pictureFrozen = false
    private var livePictureFrozen = false
    private var latestLiveFrame: CGImage?
    private var appTerminationObserver: NSObjectProtocol?
    private var automationRetry: [MediaSource: Date] = [:]

    private var capture: WindowCapture?
    private var nativePlayer: AVPlayer?
    private var youtubePlayer: YouTubePlayback?
    private var nativeSource: NativeSource?
    private var mediaKeyTargets: [(MPRemoteCommand, Any)] = []
    private var nowPlayingState: MPNowPlayingPlaybackState = .stopped
    private var lastDiscovery = Date.distantPast
    private var lastVideoCrop: CGRect?
    private var cropAdjustment: CGRect?
    private var captureRequest = UUID()
    private var captureStarting = false
    private var enabled: Set<MediaSource> = []
    private var failure: [MediaSource: String] = [:]
    private var lastOffered: [MediaSource: String] = [:]
    private var pendingOffer: Offer?
    private var offerPanel: NSPanel?
    private var cropWindow: NSWindow?
    private var playingSource: (source: MediaSource, id: String, windowID: Int?)?
    private var sourceUnavailable = false
    private var activeProbes = 0
    private var playerReady = false
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["hoverTransparency": player.hoverTransparency,
                                     "showsCommandHint": player.showsCommandHint])
        player.hoverTransparency = min(100, max(0, defaults.integer(forKey: "hoverTransparency")))
        player.showsCommandHint = defaults.bool(forKey: "showsCommandHint")
        player.bind(to: self)
        shortcuts.perform = { [weak self] action in
            switch action {
            case .visibility: self?.toggleVisibility()
            case .close: self?.closePlayer()
            }
        }
        shortcuts.start()
        enabled = Set((defaults.stringArray(forKey: "sources") ?? MediaSource.allCases.map(\.rawValue))
            .compactMap(MediaSource.init(rawValue:)))
        safariBridge.didOffer = { [weak self] video, open in self?.extensionOffer(video, open: open) }
        safariBridge.didWithdraw = { [weak self] id in
            guard let self else { return }
            if extensionOfferID == id { extensionOfferID = nil }
            if safariMirror == id || bridgeOpening == id {
                safariMirrorRevision += 1
                if safariMirror == id { holdSource() }
            }
            if case .safariExtension(let video) = pendingOffer, video.id == id { dismissOffer() }
        }
        safariBridge.didLoseSource = { [weak self] id in
            self?.safariSourceLost(id)
        }
        safariBridge.didReceiveFrame = { [weak self] id, media, image in
            guard let self, safariBridge.frameVideo == id else { return }
            safariFramePaused = media.paused
            player.playbackState(media.paused, seekable: media.seekable == true)
            player.showTime(media.time, duration: media.duration)
            if let image {
                safariFrameAt = Date()
                if !livePictureFrozen { player.showSourceStatus(nil) }
                let first = !playerReady
                displayFrame(image)
                if first { rebuildMenu() }
            }
        }
        safariBridge.start()
        rebuildMenu()
        let interaction = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.updateInteraction() }
        }
        RunLoop.main.add(interaction, forMode: .common)
        let detection = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.detect() }
        }
        RunLoop.main.add(detection, forMode: .common)
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.sourceApplicationDidTerminate(app) }
        }
        offerSafariExtensionInstall()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateLater }
        guard nativeSource != nil || !handbacks.isEmpty || safariOpening != nil else { return .terminateNow }
        terminating = true
        let opening = safariOpening?.task
        closePlayer()
        let pending = Array(handbacks.values)
        Task {
            if let opening { await opening.value }
            for handback in pending { await handback.value }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
        clearMediaKeys()
        if let appTerminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver) }
    }

    private func safariSourceLost(_ id: UUID) {
        if case .safariExtension(let activeID) = nativeSource, activeID == id {
            nativeSource = nil
            closePlayer()
        } else if safariBridge.frameVideo == id || safariMirror == id || bridgeOpening == id {
            finishLostCapture()
        }
    }

    private func sourceApplicationDidTerminate(_ app: NSRunningApplication) {
        if app.processIdentifier == sourceProcessID {
            finishLostCapture()
        } else if app.bundleIdentifier == MediaSource.safari.rawValue {
            if let id = safariBridge.frameVideo ?? safariMirror ?? bridgeOpening {
                safariSourceLost(id)
            } else if case .safariExtension(let id) = nativeSource {
                safariSourceLost(id)
            }
        }
        if case .browser(let source, _) = nativeSource, source.rawValue == app.bundleIdentifier {
            nativeSource = nil
            closePlayer()
        }
    }

    private func finishLostCapture() {
        if livePictureFrozen { retainPicture(message: "Son kare sabitlendi") }
        else { closePlayer() }
    }

    private func item(_ title: String, _ action: Selector?, icon: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let icon {
            item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
        return item
    }

    private func group(_ title: String, _ menu: NSMenu, icon: String) -> NSMenuItem {
        let entry = item(title, nil, icon: icon)
        entry.submenu = menu
        return entry
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let hasOffer = offerPanel != nil
        let symbol = NSImage(systemSymbolName: hasOffer ? "pip.enter" : "pip",
                             accessibilityDescription: hasOffer ? "Kadraj, video bulundu" : "Kadraj")
        if hasOffer {
            let highlighted = symbol?.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) ?? symbol
            highlighted?.isTemplate = false
            status.button?.image = highlighted
        } else {
            status.button?.image = symbol
        }
        status.button?.toolTip = hasOffer ? "Video bulundu · Kadraj’da aç"
            : handbackFailed ? "Son oynatma konumu tarayıcıya aktarılamadı" : "Kadraj"
        if pendingOffer != nil {
            menu.addItem(item("Bulunan videoyu Kadraj’da aç", #selector(acceptOffer), icon: "pip.enter"))
            menu.addItem(.separator())
        }
        let captureMenu = NSMenu()
        captureMenu.addItem(item("Videoyu yakala…", #selector(chooseWindow), icon: "viewfinder"))
        captureMenu.addItem(item("Pencereyi canlı sabitle…", #selector(chooseLiveWindow), icon: "macwindow"))
        captureMenu.addItem(item("Görüntüyü sabitle…", #selector(chooseStill), icon: "photo"))
        menu.addItem(group("Yakalama", captureMenu, icon: "viewfinder"))
        menu.addItem(item("Safari’ye bağlan…", #selector(connectSafari), icon: "safari"))

        let playerMenu = NSMenu()
        if hasPicture {
            playerMenu.addItem(item(hiddenByUser ? "Kadrajı göster" : "Kadrajı gizle",
                                    #selector(toggleVisibility), icon: hiddenByUser ? "eye" : "eye.slash"))
        }
        if playerReady, pictureFrozen || capture != nil || safariBridge.frameVideo != nil {
            let frozen = livePictureFrozen || pictureFrozen
            playerMenu.addItem(item(frozen ? "Sabitlemeyi kaldır" : "Son kareyi sabitle",
                                    #selector(togglePictureFreeze), icon: frozen ? "pin.slash" : "pin"))
        }
        if hasPicture || capture != nil || captureStarting {
            playerMenu.addItem(item("Pencereyi kapat", #selector(closePlayer), icon: "xmark"))
        }
        if handbackFailed {
            playerMenu.addItem(item("Son konum tarayıcıya aktarılamadı", nil, icon: "exclamationmark.triangle"))
        }
        if playerMenu.numberOfItems > 0 { menu.addItem(group("Pencere", playerMenu, icon: "pip")) }

        let sources = NSMenu()
        for source in MediaSource.allCases {
            let icon = source == .safari ? "safari" : source == .quickTime ? "play.rectangle" : "globe"
            let entry = item(source.name + (failure[source] == nil ? "" : " · Ayar gerekli"),
                             #selector(toggleSource(_:)), icon: icon)
            entry.representedObject = source.rawValue
            entry.state = enabled.contains(source) ? .on : .off
            sources.addItem(entry)
            if failure[source] != nil {
                let retry = item(source.name + " bağlantısını dene", #selector(retrySource(_:)), icon: "arrow.clockwise")
                retry.representedObject = source.rawValue
                sources.addItem(retry)
            }
        }
        if !accessibility.trusted {
            sources.addItem(item("Erişilebilirlik iznini aç…", #selector(requestAccessibility), icon: "accessibility"))
        }
        let actions = NSMenu()
        for action in PlayerShortcutAction.allCases {
            let shortcut = shortcuts.shortcut(for: action)
            let label = shortcuts.isActive(action) ? shortcut.label : shortcut.label + " · Kullanılamıyor"
            let entry = item(action.title + "    " + label, #selector(editShortcut(_:)),
                             icon: action == .visibility ? "eye" : "xmark")
            entry.tag = Int(action.rawValue)
            actions.addItem(entry)
        }
        let settings = NSMenu()
        settings.addItem(group("Video algılama", sources, icon: "dot.radiowaves.left.and.right"))
        settings.addItem(group("Klavye kısayolları", actions, icon: "keyboard"))
        let hint = item("⌘ kontrol ipucunu göster", #selector(toggleCommandHint), icon: "command")
        hint.state = player.showsCommandHint ? .on : .off
        settings.addItem(hint)
        settings.addItem(item("Fare üzerindeyken saydamlık…", #selector(editTransparency), icon: "slider.horizontal.3"))
        settings.addItem(item("Safari uzantısını etkinleştir…", #selector(openSafariExtensionSettings), icon: "puzzlepiece.extension"))
        settings.addItem(item("Kullanım ve izinler…", #selector(showHelp), icon: "questionmark.circle"))
        menu.addItem(group("Ayarlar", settings, icon: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(item("Kadraj’dan çık", #selector(quit), icon: "power", key: "q"))
        status.menu = menu
    }

    @objc private func toggleCommandHint() {
        player.showsCommandHint.toggle()
        defaults.set(player.showsCommandHint, forKey: "showsCommandHint")
        player.updateInteraction()
        rebuildMenu()
    }

    @objc private func editTransparency() {
        let title = "Fare üzerindeyken saydamlık"
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = "%0 tam görünür, %100 görünmez."
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        let slider = NSSlider(value: Double(player.hoverTransparency), minValue: 0, maxValue: 100,
                              target: self, action: #selector(changeTransparency(_:)))
        slider.setAccessibilityLabel(title)
        slider.isContinuous = true
        let controls = NSStackView(views: [label, slider])
        controls.orientation = .vertical
        controls.spacing = 8
        controls.frame = NSRect(x: 0, y: 0, width: 260, height: 45)
        slider.widthAnchor.constraint(equalToConstant: 250).isActive = true
        dialog.accessoryView = controls
        changeTransparency(slider)
        dialog.addButton(withTitle: "Bitti")
        NSApp.activate()
        dialog.runModal()
    }

    @objc private func changeTransparency(_ slider: NSSlider) {
        let value = Int(slider.doubleValue.rounded())
        if let controls = slider.superview as? NSStackView, let label = controls.arrangedSubviews.first as? NSTextField {
            label.stringValue = "%\(value)"
        }
        player.hoverTransparency = value
        defaults.set(value, forKey: "hoverTransparency")
        player.updateInteraction()
    }

    @objc private func editShortcut(_ sender: NSMenuItem) {
        guard let action = PlayerShortcutAction(rawValue: UInt32(sender.tag)) else { return }
        let dialog = NSAlert()
        dialog.messageText = action.title
        dialog.informativeText = "⌃, ⌥ veya ⌘ ile bir tuşa basın. İsterseniz ⇧ de ekleyin."
        let label = NSTextField(labelWithString: shortcuts.shortcut(for: action).label)
        label.frame = NSRect(x: 0, y: 0, width: 260, height: 27)
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.alignment = .center
        dialog.accessoryView = label
        let save = dialog.addButton(withTitle: "Kaydet")
        save.isEnabled = false
        dialog.addButton(withTitle: "Vazgeç")
        var candidate: PlayerShortcut?
        shortcuts.suspend()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === dialog.window, let shortcut = PlayerShortcut(event: event) else { return event }
            candidate = shortcut
            label.stringValue = shortcut.label
            save.isEnabled = true
            return nil
        }
        NSApp.activate()
        let response = dialog.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        shortcuts.start()
        if response == .alertFirstButtonReturn, let candidate, !shortcuts.replace(action, with: candidate) {
            alert("Kısayol kullanılamıyor", "Bu kombinasyon başka bir işleme atanmış veya macOS tarafından kullanılıyor.")
        }
        rebuildMenu()
    }

    @objc private func toggleSource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let source = MediaSource(rawValue: id) else { return }
        if enabled.remove(source) != nil {
            if pendingOffer?.source == source { dismissOffer() }
            if playingSource?.0 == source || (source == .safari && (safariMirror != nil || safariBridge.frameVideo != nil)) ||
                trackedAccessible.map({ NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == source.rawValue }) == true {
                freezePicture()
            }
        } else {
            enabled.insert(source)
            lastOffered[source] = nil
        }
        failure[source] = nil
        automationRetry[source] = nil
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "sources")
        rebuildMenu()
        if enabled.contains(source) { detect() }
    }

    @objc private func retrySource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let source = MediaSource(rawValue: id) else { return }
        let detail = failure.removeValue(forKey: source)
        automationRetry[source] = nil
        rebuildMenu()
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != source.rawValue {
            alert("Tarayıcıyı veya oynatıcıyı öne getirin", "Kadraj, seçtiğiniz uygulamada video oynarken bağlantıyı yeniden deneyecek.\n\n" + (detail ?? ""))
        }
        detect()
    }

    @objc private func requestAccessibility() {
        accessibility.requestAccess()
    }

    private func detect() {
        guard !terminating else { return }
        if let id = sourceWindowID, WindowStamp.read(id) == nil {
            finishLostCapture()
            return
        }
        if safariBridge.frameVideo != nil, safariBridge.frameContactAt.duration(to: .now) > .seconds(15) {
            safariBridge.abandonFrames()
            finishLostCapture()
            return
        }
        guard activeProbes == 0, !captureStarting, cropWindow == nil else { return }
        if let player = nativePlayer {
            self.player.playbackState(player.timeControlStatus == .paused, seekable: NativePlayback.canSeek(player))
            self.player.showTime(player.currentTime().seconds, duration: player.currentItem?.duration.seconds)
            updateNowPlaying(player)
        } else if let youtubePlayer {
            refreshYouTube(youtubePlayer)
        } else if let frameVideo = safariBridge.frameVideo {
            inspectSafariFrames(frameVideo)
        } else if let safariMirror {
            inspectSafariMirror(safariMirror)
        } else if let trackedAccessible {
            inspectAccessible(trackedAccessible)
        } else if let (source, identifier, windowID) = playingSource {
            if NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).isEmpty {
                closePlayer()
                return
            }
            inspect(source, id: identifier, windowID: windowID)
        } else if capture == nil, Date().timeIntervalSince(lastDiscovery) >= 0.95,
                  let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
                  let source = MediaSource(rawValue: id), enabled.contains(source) {
            lastDiscovery = Date()
            if source == .safari, Date().timeIntervalSince(lastExtensionVideo) < 3 { return }
            if let retry = automationRetry[source], retry > Date() {
                discoverAccessible(source, pid: app.processIdentifier)
            } else {
                inspect(source)
            }
        }
    }

    private func inspect(_ source: MediaSource, id: String? = nil, action: PlaybackAction? = nil,
                         windowID: Int? = nil) {
        let request = captureRequest
        activeProbes += 1
        probe.run(source, selected: id, action: action, windowID: windowID) { [weak self] result in
            guard let self else { return }
            activeProbes -= 1
            guard captureRequest == request, enabled.contains(source) else { return }
            if id == nil, source == .safari, Date().timeIntervalSince(lastExtensionVideo) < 3 { return }
            switch result {
            case .failure(let error):
                let wasMissing = failure[source] == nil
                failure[source] = error.localizedDescription
                automationRetry[source] = Date().addingTimeInterval(15)
                if id != nil {
                    holdSource()
                } else if let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).first {
                    discoverAccessible(source, pid: app.processIdentifier)
                }
                if wasMissing { rebuildMenu() }
            case .success(let media):
                if failure.removeValue(forKey: source) != nil { rebuildMenu() }
                if id != nil {
                    guard let media, !media.crop.isEmpty,
                          let stamp = sourceWindowID.flatMap(WindowStamp.read),
                          source == .quickTime || media.matchesWindow(stamp.frame) else {
                        holdSource()
                        return
                    }
                    followSource(media.crop, stamp: stamp, paused: media.paused, seekable: media.seekable == true)
                    player.showTime(media.time, duration: media.duration)
                } else if let media, !media.crop.isEmpty {
                    guard lastOffered[source] != media.id else { return }
                    lastOffered[source] = media.id
                    showOffer(.browser(source, media), subtitle: [source.name, media.title].filter { !$0.isEmpty }.joined(separator: " · "))
                } else {
                    lastOffered[source] = nil
                    if case .browser(let offered, _) = pendingOffer, offered == source { dismissOffer() }
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).first {
                        discoverAccessible(source, pid: app.processIdentifier)
                    }
                }
            }
        }
    }

    private func discoverAccessible(_ source: MediaSource, pid: pid_t) {
        guard accessibility.trusted else { return }
        let request = captureRequest
        activeProbes += 1
        accessibility.discover(pid: pid, includePaused: false) { [weak self] video in
            guard let self else { return }
            activeProbes -= 1
            guard captureRequest == request, enabled.contains(source), capture == nil, nativePlayer == nil,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let video else {
                lastAXOffer = nil
                if case .accessibility(let offered, _) = pendingOffer, offered == source { dismissOffer() }
                return
            }
            guard video.id != lastAXOffer else { return }
            lastAXOffer = video.id
            showOffer(.accessibility(source, video), subtitle: source.name)
        }
    }

    private func inspectAccessible(_ video: AccessibleVideo, toggle: Bool = false) {
        let request = captureRequest
        activeProbes += 1
        accessibility.refresh(video, toggle: toggle) { [weak self] current in
            guard let self else { return }
            activeProbes -= 1
            guard captureRequest == request else { return }
            guard let current, !current.crop.isEmpty,
                  let stamp = sourceWindowID.flatMap(WindowStamp.read), current.matchesWindow(stamp.frame) else {
                holdSource()
                return
            }
            trackedAccessible = current
            followSource(current.crop, stamp: stamp, paused: current.paused)
        }
    }

    private func holdSource() {
        guard !sourceUnavailable else { return }
        sourceUnavailable = true
        capture?.suspend()
        if !livePictureFrozen { player.showSourceStatus("Kaynak görünmüyor · Son kare") }
        player.playbackState(nil)
    }

    private func followSource(_ region: CGRect, stamp: WindowStamp, paused: Bool?, seekable: Bool = false) {
        let changed = sourceUnavailable || acceptedStamp?.sameContent(as: stamp) != true
        if changed { capture?.suspend() }
        sourceUnavailable = false
        acceptedStamp = stamp
        lastVideoCrop = region
        let crop = cropAdjustment.map { Crop.applying($0, to: region) } ?? region
        capture?.setCrop(crop)
        if !livePictureFrozen { player.showSourceStatus(nil) }
        player.playbackState(paused, seekable: seekable)
    }

    private func showOffer(_ offer: Offer, subtitle text: String) {
        dismissOffer()
        pendingOffer = offer
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 338, height: 133),
                            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let header = NSTextField(labelWithString: "Videoyu Kadraj’da açayım mı?")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: text)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let cancel = NSButton(title: "Şimdi değil", target: self, action: #selector(dismissOffer))
        let open = NSButton(title: "Kadraj’da aç", target: self, action: #selector(acceptOffer))
        open.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [cancel, open])
        buttons.spacing = 8
        let stack = NSStackView(views: [header, subtitle, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let view = panel.contentView else { return }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.maxY - panel.frame.height - 14))
        }
        offerPanel = panel
        rebuildMenu()
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak panel] in
            guard let self, let panel, offerPanel === panel else { return }
            hideOfferPanel()
        }
    }

    private func hideOfferPanel() {
        offerPanel?.orderOut(nil)
        offerPanel = nil
        rebuildMenu()
    }

    @objc private func dismissOffer() {
        offerPanel?.orderOut(nil)
        offerPanel = nil
        if pendingOffer != nil {
            pendingOffer = nil
            rebuildMenu()
        }
    }

    @objc private func connectSafari() {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MediaSource.safari.rawValue) else {
            alert("Safari bulunamadı", "Safari’nin bu Mac’te kurulu olduğundan emin olun.")
            return
        }
        guard let url = safariBridge.makePairingURL() else {
            alert("Safari bağlantısı hazır değil", "Başka bir Kadraj açık olabilir. Eski sürümü kapatıp tekrar deneyin.")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: safari,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func offerSafariExtensionInstall() {
        guard !defaults.bool(forKey: "safariExtensionSetupOffered") else { return }
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.safariExtensionID) { [weak self] state, _ in
            let enabled = state?.isEnabled == true
            DispatchQueue.main.async {
                guard let self, !self.terminating else { return }
                self.defaults.set(true, forKey: "safariExtensionSetupOffered")
                guard !enabled else { return }
                let prompt = NSAlert()
                prompt.messageText = "Kadraj Safari uzantısı etkinleştirilsin mi?"
                prompt.informativeText = "Uzantı uygulamayla birlikte geliyor. Safari’nin ayarları açılınca Kadraj Safari kutusunu işaretleyin."
                prompt.addButton(withTitle: "Evet, Safari’yi aç")
                prompt.addButton(withTitle: "Şimdi değil")
                NSApp.activate()
                if prompt.runModal() == .alertFirstButtonReturn {
                    self.openSafariExtensionSettings()
                }
            }
        }
    }

    @objc private func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.safariExtensionID) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                self?.alert("Safari uzantısı ayarı açılamadı",
                            "Safari → Ayarlar → Uzantılar bölümünde Kadraj Safari’yi işaretleyin. Bu yerel derlemede uzantı listelenmiyorsa Safari’nin Geliştirici ayarlarında imzasız uzantılara izin verin.")
            }
        }
    }

    private func extensionOffer(_ video: SafariVideo, open: Bool) {
        lastExtensionVideo = Date()
        guard !terminating, bridgeOpening == nil else { return }
        let version = video.protocolVersion ?? 0
        if video.supportsHandback != true || (video.mirrorOnly == true && version < 2)
            || (video.youtubeID != nil && version < 3) {
            if open { alert("Safari uzantısını güncelleyin", "Kadraj menüsünden uygulamayla gelen Safari uzantısını etkinleştirin.") }
            return
        }
        if safariMirror == video.id || safariBridge.frameVideo == video.id { return }
        if case .safariExtension(let activeID) = nativeSource, activeID == video.id { return }
        if open {
            dismissOffer()
            openSafariVideo(video)
        } else if enabled.contains(.safari), !captureStarting, capture == nil, nativePlayer == nil, youtubePlayer == nil,
                  safariBridge.frameVideo == nil,
                  extensionOfferID != video.id,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == MediaSource.safari.rawValue {
            extensionOfferID = video.id
            showOffer(.safariExtension(video), subtitle: video.title.isEmpty ? "Safari" : "Safari · " + video.title)
        }
    }

    private func openSafariVideo(_ video: SafariVideo) {
        guard bridgeOpening == nil, enabled.contains(.safari) else { return }
        if video.youtubeID != nil {
            closePlayer()
            safariBridge.frameVideo = video.id
            updateSafariFrameSize()
            safariFrameAt = Date()
            safariFramePaused = false
            player.hideCropControl()
        }
        bridgeOpening = video.id
        captureStarting = true
        let request = captureRequest
        rebuildMenu()
        let openingID = UUID()
        let task = Task {
            defer {
                if safariOpening?.id == openingID { safariOpening = nil }
                if bridgeOpening == video.id {
                    bridgeOpening = nil
                    captureStarting = false
                    rebuildMenu()
                }
            }
            if video.youtubeID != nil {
                let reply = await safariBridge.request(.startFrames, video: video.id)
                guard captureRequest == request else { return }
                if reply?.success == true {
                    if !playerReady { safariFrameAt = Date() }
                } else {
                    safariBridge.abandonFrames()
                    closePlayer()
                    if reply?.failure != "restricted", extensionOfferID == video.id { extensionOfferID = nil }
                    switch reply?.failure {
                    case "restricted":
                        alert("Safari görüntü erişimini kısıtlıyor", "Bu videonun karelerini Kadraj’a aktarmak için Safari erişim vermedi.")
                    case "notReady":
                        alert("Video görüntüsü henüz hazır değil", "Safari’deki video görüntüsü geldikten sonra Kadraj’dan tekrar açın.")
                    case "sourceChanged":
                        alert("Safari’deki video değişti", "Oynayan video için Kadraj menüsündeki yeni öneriyi kullanın.")
                    case "captureUnavailable":
                        alert("Safari görüntü aktarımını başlatamadı", "Safari’de video sekmesini yenileyip tekrar deneyin.")
                    default:
                        alert("Safari video aktarımına yanıt vermedi", "Safari’de video sekmesini açıp Kadraj’dan tekrar deneyin.")
                    }
                }
                return
            }
            if video.mirrorOnly == true {
                await openSafariMirror(video.id, request: request)
                return
            }
            guard let handoff = await safariBridge.transfer(video.id, while: { captureRequest == request }) else {
                if captureRequest == request {
                    if video.canMirror == true { await openSafariMirror(video.id, request: request) }
                    else { showSafariTransferError() }
                }
                return
            }
            guard captureRequest == request else {
                _ = await safariBridge.returnPlayback(video.id, at: handoff.source.time, play: !handoff.source.paused)
                return
            }
            presentNative(handoff.player, paused: handoff.source.paused, volume: handoff.source.volume,
                          source: .safariExtension(video.id))
        }
        safariOpening = (openingID, task)
    }

    private func inspectSafariFrames(_ id: UUID) {
        updateSafariFrameSize()
        let age = Date().timeIntervalSince(safariFrameAt)
        if !playerReady && age > 6 {
            safariBridge.abandonFrames()
            closePlayer()
            alert("Safari’den görüntü gelmedi", "Video sekmesini açıp Kadraj’da aç’a yeniden basın.")
            return
        }
        if playerReady && age > 5 && !safariFramePaused {
            player.showSourceStatus("Safari’den görüntü bekleniyor")
        }
        guard let action = safariMirrorControl else { return }
        safariMirrorControl = nil
        activeProbes += 1
        Task {
            let reply = await safariBridge.request(action, video: id)
            activeProbes -= 1
            guard safariBridge.frameVideo == id, let media = reply?.media else { return }
            safariFramePaused = media.paused
            player.playbackState(media.paused, seekable: media.seekable == true)
            player.showTime(media.time, duration: media.duration)
            if action == .toggle, reply?.success == false, media.paused {
                player.showSourceStatus("Oynatmak için Safari’deki videoyu başlatın")
            }
        }
    }

    private func updateSafariFrameSize() {
        let scale = player.backingScaleFactor
        let size = player.frame.size
        let width = min(1920, max(64, Int(ceil(size.width * scale / 64)) * 64))
        let height = min(1080, max(64, Int(ceil(size.height * scale / 64)) * 64))
        safariBridge.frameSize = [width, height]
    }

    private func presentYouTube(_ embed: YouTubePlayback, source: NativeSource, time: Double,
                                duration: Double?, volume: Double, paused: Bool) {
        closePlayer()
        handbackFailed = false
        youtubePlayer = embed
        nativeSource = source
        player.showWebPlayer(embed.view)
        player.playbackState(paused, seekable: duration != nil)
        player.showTime(time, duration: duration)
        showPlayerIfNeeded()
        registerMediaKeys { [weak self, weak embed] key in
            guard let embed, self?.youtubePlayer === embed else { return }
            embed.setPlaying(key == .toggle ? !embed.playing : key == .play)
        }
        embed.start(time: time, duration: duration, volume: volume, playing: !paused)
        rebuildMenu()
    }

    private func refreshYouTube(_ embed: YouTubePlayback) {
        activeProbes += 1
        Task {
            await embed.refresh()
            activeProbes -= 1
            guard youtubePlayer === embed else { return }
            if let code = embed.errorCode {
                closePlayer()
                showYouTubeError(code)
                return
            }
            player.playbackState(!embed.playing, seekable: embed.duration != nil)
            player.showTime(embed.time, duration: embed.duration)
            updateNowPlaying(playing: embed.playing)
        }
    }

    private func showYouTubeError(_ code: Int? = nil) {
        let detail = [100, 101, 150].contains(code ?? 0)
            ? "Bu video YouTube’un gömülü oynatıcısında kullanılamıyor. Safari’den izlemeye devam edebilirsiniz."
            : "YouTube oynatıcısı veya Safari bağlantısı hazır değil. Videoyu Safari’de açıp yeniden deneyin."
        alert("YouTube videosu açılamadı", detail)
    }

    private func openSafariMirror(_ id: UUID, request: UUID) async {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            extensionOfferID = nil
            showScreenPermission()
            return
        }
        let revision = safariMirrorRevision
        guard let media = await safariBridge.request(.describe, video: id)?.media,
              let geometry = media.mirror, !geometry.region.isEmpty,
              captureRequest == request, safariMirrorRevision == revision else {
            if captureRequest == request {
                extensionOfferID = nil
                alert("Safari videosu görünmüyor", "Video sekmesini öne getirip oynatıcı ekrandayken Kadraj’da aç’a yeniden basın.")
            }
            return
        }

        do {
            let windows = try await availableWindows().filter {
                $0.owningApplication?.bundleIdentifier == MediaSource.safari.rawValue
                    && geometry.matches(frame: $0.frame, title: $0.title)
            }
            guard captureRequest == request, safariMirrorRevision == revision else { return }
            guard windows.count == 1, let window = windows.first,
                  let stamp = WindowStamp.read(window.windowID),
                  geometry.matches(frame: stamp.frame, title: stamp.title) else {
                extensionOfferID = nil
                alert("Safari penceresi eşleşmedi", "Video Safari’de görünürken tekrar deneyin.")
                return
            }
            await startCapture(window, crop: geometry.region, stamp: stamp, safariMirrorID: id)
        } catch {
            if captureRequest == request {
                extensionOfferID = nil
                alert("Safari penceresi okunamadı", error.localizedDescription)
            }
        }
    }

    private func inspectSafariMirror(_ id: UUID) {
        let operation = safariMirrorControl ?? .describe
        safariMirrorControl = nil
        let request = captureRequest
        let revision = safariMirrorRevision
        activeProbes += 1
        Task {
            let reply = await safariBridge.request(operation, video: id)
            activeProbes -= 1
            guard captureRequest == request, safariMirror == id, safariMirrorRevision == revision else { return }
            guard let media = reply?.media, let geometry = media.mirror, !geometry.region.isEmpty,
                  let stamp = sourceWindowID.flatMap(WindowStamp.read),
                  geometry.matches(frame: stamp.frame, title: stamp.title) else {
                holdSource()
                return
            }
            safariMirrorFreshUntil = Date().addingTimeInterval(1.8)
            followSource(geometry.region, stamp: stamp, paused: media.paused, seekable: media.seekable == true)
            player.showTime(media.time, duration: media.duration)
        }
    }

    private func showSafariTransferError() {
        alert("Video Kadraj’a aktarılamadı",
              "Safari’deki oynatma sürüyor. Bu kaynak için Kadraj menüsünden Videoyu yakala seçeneğini kullanabilirsiniz.")
    }

    @objc private func acceptOffer() {
        guard let offer = pendingOffer else { return }
        dismissOffer()
        if case .safariExtension(let video) = offer {
            openSafariVideo(video)
            return
        }
        if case .accessibility(_, let video) = offer {
            openAccessible(video)
            return
        }
        guard case .browser(let source, let offered) = offer else { return }
        let request = captureRequest
        captureStarting = true
        rebuildMenu()
        Task {
            guard let media = await probe.read(source, selected: offered.id, windowID: offered.browserWindowID,
                                               tabIndex: offered.browserTabIndex),
                  captureRequest == request, enabled.contains(source), media.youtubeID != nil || !media.crop.isEmpty else {
                if captureRequest == request {
                    closePlayer()
                    lastOffered[source] = nil
                }
                return
            }
            if let youtubeID = media.youtubeID {
                if source == .safari {
                    closePlayer()
                    alert("Kadraj Safari uzantısını etkinleştirin",
                          "Safari’de açık olan YouTube videosunu Kadraj Safari uzantısındaki Kadraj’da aç düğmesinden açın.")
                    return
                }
                await openProbedYouTube(youtubeID, media: media, source: source, request: request)
                return
            }
            if await openDirect(media, source: source, request: request) { return }
            guard captureRequest == request else { return }
            guard enabled.contains(source) else {
                closePlayer()
                return
            }

            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                closePlayer()
                lastOffered[source] = nil
                showScreenPermission()
                return
            }
            do {
                let windows = try await availableWindows()
                guard captureRequest == request else { return }
                guard enabled.contains(source) else {
                    closePlayer()
                    return
                }
                let sourceWindows = windows.filter { $0.owningApplication?.bundleIdentifier == source.rawValue }
                let matches = sourceWindows.filter { matchesVideoWindow($0, source: source, media: media) }
                guard matches.count == 1, let window = matches.first else {
                    closePlayer()
                    lastOffered[source] = nil
                    alert("Video penceresi belirlenemedi", "Pencereyi görünür tutup yeniden deneyin veya Videoyu yakala komutundan video bölgesini seçin.")
                    return
                }
                await startCapture(window, crop: media.crop, source: source, media: media)
            } catch {
                guard captureRequest == request else { return }
                closePlayer()
                alert("Pencere yakalanamadı", error.localizedDescription)
            }
        }
    }

    private func openProbedYouTube(_ id: String, media: Media, source: MediaSource, request: UUID) async {
        defer {
            if captureRequest == request {
                captureStarting = false
                rebuildMenu()
            }
        }
        guard let embed = YouTubePlayback(id: id) else { return }
        guard await embed.prepare(while: { captureRequest == request && enabled.contains(source) }),
              let current = await probe.read(source, selected: media.id, windowID: media.browserWindowID,
                                             tabIndex: media.browserTabIndex), current.youtubeID == id else {
            if captureRequest == request { showYouTubeError(embed.errorCode) }
            return
        }
        guard captureRequest == request, enabled.contains(source) else { return }
        guard let held = await probe.read(source, selected: current.id, action: .pause,
                                          windowID: current.browserWindowID, tabIndex: current.browserTabIndex),
              held.paused else {
            if captureRequest == request { showYouTubeError() }
            return
        }
        let time = held.time ?? current.time ?? 0
        let nativeSource = NativeSource.browser(source, held)
        guard captureRequest == request, enabled.contains(source) else {
            startHandback(nativeSource, time: time, play: !current.paused)
            return
        }
        presentYouTube(embed, source: nativeSource, time: time, duration: held.duration,
                       volume: held.volume ?? 1, paused: current.paused)
    }

    private func openAccessible(_ video: AccessibleVideo) {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            lastAXOffer = nil
            showScreenPermission()
            return
        }
        let request = captureRequest
        captureStarting = true
        rebuildMenu()
        accessibility.refresh(video) { [weak self] current in
            guard let self, captureRequest == request else { return }
            guard let current, !current.crop.isEmpty else {
                closePlayer()
                lastAXOffer = nil
                return
            }
            Task { [self] in
                do {
                    let windows = try await self.availableWindows()
                    guard self.captureRequest == request else { return }
                    let matches = windows.filter {
                        $0.owningApplication?.processID == current.pid && current.matchesWindow($0.frame)
                    }
                    guard matches.count == 1, let window = matches.first else {
                        self.closePlayer()
                        return
                    }
                    await self.startCapture(window, crop: current.crop, accessible: current)
                } catch {
                    guard self.captureRequest == request else { return }
                    self.closePlayer()
                    self.alert("Video penceresi yakalanamadı", error.localizedDescription)
                }
            }
        }
    }

    private func matchesVideoWindow(_ window: SCWindow, source: MediaSource, media: Media) -> Bool {
        if source == .quickTime { return String(window.windowID) == media.id || window.title == media.title }
        return media.matchesWindow(window.frame)
    }

    private func openDirect(_ media: Media, source: MediaSource, request: UUID) async -> Bool {
        guard let url = media.directURL,
              let direct = await NativePlayback.prepare(url, while: { captureRequest == request && enabled.contains(source) }),
              captureRequest == request, enabled.contains(source),
              let current = await probe.read(source, selected: media.id, windowID: media.browserWindowID), current.directURL == url,
              captureRequest == request, enabled.contains(source) else { return false }
        if let time = current.time, time > 0.05 {
            guard await NativePlayback.seek(direct, to: time) else { return false }
        }
        guard captureRequest == request, enabled.contains(source) else { return false }
        if !current.paused {
            guard let result = await probe.read(source, selected: media.id, action: .pause, windowID: media.browserWindowID), result.paused else { return false }
            guard captureRequest == request, enabled.contains(source) else {
                if NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).isEmpty == false,
                   let latest = await probe.read(source, selected: media.id, windowID: media.browserWindowID), latest.paused {
                    _ = await probe.read(source, selected: media.id, action: .toggle, windowID: media.browserWindowID)
                }
                return false
            }
        }
        presentNative(direct, paused: current.paused, volume: current.volume ?? 1, source: .browser(source, current))
        return true
    }

    private func presentNative(_ direct: AVPlayer, paused: Bool, volume: Double, source: NativeSource) {
        closePlayer()
        handbackFailed = false
        nativePlayer = direct
        nativeSource = source
        direct.volume = Float(min(1, max(0, volume)))
        player.showNativePlayer(direct)
        player.playbackState(paused, seekable: NativePlayback.canSeek(direct))
        player.showTime(direct.currentTime().seconds, duration: direct.currentItem?.duration.seconds)
        showPlayerIfNeeded()
        bindMediaKeys(to: direct)
        if !paused { direct.play() }
        updateNowPlaying(direct)
        rebuildMenu()
    }

    private enum MediaKey { case toggle, play, pause }

    private func bindMediaKeys(to direct: AVPlayer) {
        registerMediaKeys { [weak self, weak direct] key in
            guard let self, let direct, self.nativePlayer === direct else { return }
            switch key {
            case .toggle: self.control(.toggle)
            case .play: self.setNativePlayback(direct, playing: true)
            case .pause: self.setNativePlayback(direct, playing: false)
            }
        }
    }

    private func registerMediaKeys(_ perform: @escaping @MainActor (MediaKey) -> Void) {
        let commands = MPRemoteCommandCenter.shared()
        for (command, key) in [(commands.togglePlayPauseCommand, MediaKey.toggle),
                               (commands.playCommand, MediaKey.play),
                               (commands.pauseCommand, MediaKey.pause)] {
            let target = command.addTarget { _ in
                DispatchQueue.main.async { perform(key) }
                return .success
            }
            command.isEnabled = true
            mediaKeyTargets.append((command, target))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Kadraj"]
    }

    private func updateNowPlaying(_ direct: AVPlayer) {
        if direct.currentItem?.status == .failed { clearMediaKeys() }
        updateNowPlaying(playing: direct.timeControlStatus != .paused)
    }

    private func updateNowPlaying(playing: Bool) {
        guard !mediaKeyTargets.isEmpty else { return }
        let state: MPNowPlayingPlaybackState = playing ? .playing : .paused
        guard state != nowPlayingState else { return }
        nowPlayingState = state
        MPNowPlayingInfoCenter.default().playbackState = state
    }

    private func clearMediaKeys() {
        guard !mediaKeyTargets.isEmpty else { return }
        for (command, target) in mediaKeyTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        mediaKeyTargets.removeAll()
        nowPlayingState = .stopped
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setNativePlayback(_ direct: AVPlayer, playing: Bool) {
        if playing {
            guard direct.timeControlStatus == .paused else { return }
            if let item = direct.currentItem,
               direct.currentTime().seconds >= item.duration.seconds - 0.05 {
                direct.seek(to: .zero)
            }
            direct.play()
        } else {
            direct.pause()
        }
        player.playbackState(direct.timeControlStatus == .paused, seekable: NativePlayback.canSeek(direct))
        updateNowPlaying(direct)
    }

    private func availableWindows() async throws -> [SCWindow] {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows
            .filter {
                $0.windowLayer == 0 && $0.frame.width >= 140 && $0.frame.height >= 95
                    && $0.owningApplication != nil
                    && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }
    }

    @objc private func chooseWindow() { chooseSource(.video) }
    @objc private func chooseLiveWindow() { chooseSource(.window) }
    @objc private func chooseStill() { chooseSource(.still) }

    private func chooseSource(_ mode: SelectionMode) {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showScreenPermission()
            return
        }
        Task { [self] in
            do {
                let windows = try await availableWindows()
                guard !windows.isEmpty else {
                    alert("Yakalanabilecek pencere bulunamadı", "Videonun açık olduğu pencereyi görünür duruma getirin.")
                    return
                }
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
                picker.addItems(withTitles: windows.enumerated().map { index, window in
                    "\(index + 1). \(window.owningApplication?.applicationName ?? "") · \(window.title ?? "Pencere")"
                })
                let dialog = NSAlert()
                dialog.messageText = "Hangi pencereyi yakalayalım?"
                switch mode {
                case .video:
                    dialog.informativeText = "Kadraj bu penceredeki videoyu arar. Gerekirse video bölgesini elle seçebilirsiniz."
                case .window:
                    dialog.informativeText = "Görüşme için ayrı bir pencere seçin. Kadraj o pencereyi canlı tutar."
                case .still:
                    dialog.informativeText = "Seçeceğiniz görüntü tek kare olarak ekranda kalır."
                }
                dialog.accessoryView = picker
                dialog.addButton(withTitle: "Devam")
                dialog.addButton(withTitle: "Vazgeç")
                NSApp.activate()
                guard dialog.runModal() == .alertFirstButtonReturn, windows.indices.contains(picker.indexOfSelectedItem) else { return }
                let window = windows[picker.indexOfSelectedItem]
                if mode == .window {
                    dismissOffer()
                    await startCapture(window, crop: Crop.full, fullWindow: true)
                    return
                }
                let still = mode == .still
                closePlayer()
                dismissOffer()
                let request = captureRequest
                captureStarting = true
                rebuildMenu()
                if !still, let id = window.owningApplication?.bundleIdentifier,
                   let source = MediaSource(rawValue: id), enabled.contains(source), failure[source] == nil,
                   let media = await probe.read(source, includePaused: true, windowBounds: window.frame), !media.crop.isEmpty,
                   captureRequest == request, matchesVideoWindow(window, source: source, media: media) {
                    if await openDirect(media, source: source, request: request) { return }
                    guard captureRequest == request else { return }
                    if enabled.contains(source) {
                        await startCapture(window, crop: media.crop, source: source, media: media)
                        return
                    }
                }
                if !still, let app = window.owningApplication, accessibility.trusted {
                    let recognized: AccessibleVideo? = await withCheckedContinuation { continuation in
                        accessibility.discover(pid: app.processID, includePaused: true) { continuation.resume(returning: $0) }
                    }
                    guard captureRequest == request else { return }
                    if let recognized, recognized.matchesWindow(window.frame) {
                        await startCapture(window, crop: recognized.crop, accessible: recognized)
                        return
                    }
                }
                guard request == captureRequest else { return }
                let image = try await WindowCapture.snapshot(of: window)
                guard request == captureRequest else { return }
                captureStarting = false
                rebuildMenu()
                showCrop(image, still: still) { [weak self] crop in
                    guard let self, captureRequest == request else { return }
                    if still {
                        showStill(image, crop: crop)
                    } else if WindowStamp.read(window.windowID) != nil {
                        Task { await self.startCapture(window, crop: crop, reference: image) }
                    }
                }
            } catch {
                if captureStarting { closePlayer() }
                alert("Pencereler okunamadı", error.localizedDescription)
            }
        }
    }

    private func startCapture(_ window: SCWindow, crop: CGRect,
                              source: MediaSource? = nil, media: Media? = nil,
                              accessible: AccessibleVideo? = nil, reference: CGImage? = nil,
                              stamp: WindowStamp? = nil, fullWindow: Bool = false,
                              safariMirrorID: UUID? = nil) async {
        closePlayer()
        let request = captureRequest
        captureStarting = true
        sourceWindowID = window.windowID
        sourceProcessID = window.owningApplication?.processID
        acceptedStamp = stamp ?? WindowStamp.read(window.windowID)
        safariMirror = safariMirrorID
        if safariMirrorID != nil { safariMirrorFreshUntil = Date().addingTimeInterval(1.8) }
        let manual = reference != nil
        if fullWindow { player.hideCropControl() }
        if let reference, let preview = reference.cropping(to: Crop.raster(crop, in: reference)) {
            displayFrame(preview)
        }
        let next = WindowCapture(window: window, crop: crop) { [weak self] image in
            guard let self, captureRequest == request, !sourceUnavailable else { return }
            if safariMirrorID != nil, safariMirrorFreshUntil <= Date() {
                holdSource()
                return
            }
            if !fullWindow && !manual {
                guard let current = WindowStamp.read(window.windowID) else {
                    finishLostCapture()
                    return
                }
                guard let expected = acceptedStamp, current.sameContent(as: expected) else {
                    holdSource()
                    return
                }
            }
            displayFrame(image)
        } onStop: { [weak self] error in
            guard let self, captureRequest == request else { return }
            if WindowStamp.read(window.windowID) == nil {
                finishLostCapture()
            } else if livePictureFrozen {
                retainPicture(message: "Son kare sabitlendi")
            } else if playerReady {
                retainPicture(message: "Pencere yayını sona erdi · Son kare", untilSourceCloses: true)
            } else {
                closePlayer()
                alert("Pencere yayını sona erdi", error.localizedDescription)
            }
        }
        capture = next
        if let source, let media { playingSource = (source, media.id, media.browserWindowID) }
        trackedAccessible = accessible
        lastVideoCrop = media?.crop ?? accessible?.crop
        player.playbackState(media?.paused ?? accessible?.paused, seekable: media?.seekable == true)
        player.showTime(media?.time, duration: media?.duration)
        rebuildMenu()
        do {
            try await next.start()
            guard captureRequest == request else {
                await next.stop()
                return
            }
            captureStarting = false
            rebuildMenu()
        } catch {
            guard captureRequest == request else { return }
            if playerReady { freezePicture() } else { closePlayer() }
            alert("Ekran yakalama başlatılamadı", error.localizedDescription)
        }
    }

    private var hasPicture: Bool { nativePlayer != nil || youtubePlayer != nil || playerReady }

    private func displayFrame(_ image: CGImage) {
        if livePictureFrozen {
            latestLiveFrame = image
            return
        }
        playerReady = true
        player.showFrame(image)
        showPlayerIfNeeded()
    }

    private func showPlayerIfNeeded() {
        guard !hiddenByUser, !player.isVisible else { return }
        player.ignoresMouseEvents = true
        player.orderFrontRegardless()
        player.updateInteraction()
    }

    @objc func toggleVisibility() {
        guard hasPicture else { return }
        hiddenByUser.toggle()
        if hiddenByUser { player.orderOut(nil) }
        else { showPlayerIfNeeded() }
        rebuildMenu()
    }

    private func showStill(_ image: CGImage, crop: CGRect) {
        guard let frame = image.cropping(to: Crop.raster(crop, in: image)) else { return }
        closePlayer()
        displayFrame(frame)
        freezePicture()
    }

    @objc func freezePicture() { retainPicture(message: "Son kare sabitlendi") }

    @objc func togglePictureFreeze() {
        if pictureFrozen {
            closePlayer()
            return
        }
        guard playerReady, capture != nil || safariBridge.frameVideo != nil else { return }
        livePictureFrozen.toggle()
        player.setPicturePin(livePictureFrozen)
        player.showSourceStatus(livePictureFrozen ? "Son kare sabitlendi" : nil)
        if !livePictureFrozen, let image = latestLiveFrame {
            displayFrame(image)
            latestLiveFrame = nil
        }
        rebuildMenu()
    }

    private func retainPicture(message: String, untilSourceCloses: Bool = false) {
        guard playerReady else {
            closePlayer()
            return
        }
        captureRequest = UUID()
        let previous = capture
        capture = nil
        playingSource = nil
        safariBridge.frameVideo = nil
        safariMirror = nil
        safariMirrorControl = nil
        trackedAccessible = nil
        acceptedStamp = nil
        if !untilSourceCloses {
            sourceWindowID = nil
            sourceProcessID = nil
        }
        livePictureFrozen = false
        latestLiveFrame = nil
        captureStarting = false
        pictureFrozen = true
        player.setPicturePin(true)
        player.playbackState(nil)
        player.showTime(nil, duration: nil)
        player.showSourceStatus(message, frozen: true)
        rebuildMenu()
        if let previous { Task { await previous.stop() } }
    }

    @objc func closePlayer() {
        clearMediaKeys()
        captureRequest = UUID()
        bridgeOpening = nil
        safariBridge.frameVideo = nil
        let previous = capture
        capture = nil
        if let embed = youtubePlayer {
            if let source = nativeSource { startHandback(source, time: embed.time, play: embed.playing) }
            embed.setPlaying(false)
        } else if let current = nativePlayer, let source = nativeSource {
            let time = current.currentTime().seconds
            let duration = current.currentItem?.duration.seconds
            let play = current.timeControlStatus != .paused
                && !(duration.map { $0.isFinite && time >= $0 - 0.05 } ?? false)
            current.pause()
            startHandback(source, time: time, play: play)
        } else {
            nativePlayer?.pause()
        }
        nativePlayer = nil
        youtubePlayer = nil
        nativeSource = nil
        hiddenByUser = false
        player.showTime(nil, duration: nil)
        player.showWebPlayer(nil)
        player.showNativePlayer(nil)
        playingSource = nil
        safariMirror = nil
        safariMirrorControl = nil
        trackedAccessible = nil
        acceptedStamp = nil
        sourceWindowID = nil
        sourceProcessID = nil
        sourceUnavailable = false
        pictureFrozen = false
        livePictureFrozen = false
        latestLiveFrame = nil
        player.setPicturePin(false)
        player.showSourceStatus(nil)
        captureStarting = false
        playerReady = false
        lastVideoCrop = nil
        cropAdjustment = nil
        cropWindow?.close()
        cropWindow = nil
        player.orderOut(nil)
        player.showFrame(nil)
        rebuildMenu()
        if let previous { Task { await previous.stop() } }
    }

    private func startHandback(_ source: NativeSource, time: Double, play: Bool) {
        let request = UUID()
        handbacks[request] = Task { [weak self] in
            guard let self else { return }
            let restored: Bool
            switch source {
            case .safariExtension(let videoID):
                restored = await safariBridge.returnPlayback(videoID, at: time, play: play)
            case .browser(let browser, let media):
                if NSRunningApplication.runningApplications(withBundleIdentifier: browser.rawValue).isEmpty {
                    restored = false
                } else {
                    let result = await probe.read(browser, selected: media.id, action: .returnPlayback,
                                                  windowID: media.browserWindowID, tabIndex: media.browserTabIndex,
                                                  returnTime: time, returnPlaying: play)
                    restored = result?.returnedPosition == true
                }
            }
            handbacks.removeValue(forKey: request)
            if !restored, !terminating {
                handbackFailed = true
                rebuildMenu()
            }
        }
    }

    @objc func togglePlayback() { control(.toggle) }
    @objc func seekBack() { control(.back) }
    @objc func seekForward() { control(.forward) }

    private func control(_ action: PlaybackAction) {
        guard !captureStarting else { return }
        if let direct = nativePlayer {
            switch action {
            case .toggle:
                setNativePlayback(direct, playing: direct.timeControlStatus == .paused)
            case .back, .forward:
                let delta = action == .back ? -10.0 : 10.0
                NativePlayback.jump(direct, by: delta)
            case .pause:
                setNativePlayback(direct, playing: false)
            case .returnPlayback:
                return
            }
        } else if let embed = youtubePlayer {
            switch action {
            case .toggle: embed.setPlaying(!embed.playing)
            case .pause: embed.setPlaying(false)
            case .back: embed.seek(by: -10)
            case .forward: embed.seek(by: 10)
            case .returnPlayback: return
            }
        } else if let source = safariBridge.frameVideo ?? safariMirror, !sourceUnavailable {
            switch action {
            case .toggle: safariMirrorControl = .toggle
            case .back: safariMirrorControl = .back
            case .forward: safariMirrorControl = .forward
            case .pause, .returnPlayback: return
            }
            if activeProbes == 0 {
                if safariBridge.frameVideo != nil { inspectSafariFrames(source) }
                else { inspectSafariMirror(source) }
            }
        } else if let trackedAccessible, action == .toggle {
            inspectAccessible(trackedAccessible, toggle: true)
        } else if let (source, id, windowID) = playingSource {
            inspect(source, id: id, action: action, windowID: windowID)
        }
    }

    @objc func selectCrop() {
        guard let capture else { return }
        capture.snapshot { [weak self, weak capture] image in
            guard let self, let capture, self.capture === capture, let image else { return }
            showCrop(image) { [weak self] rect in
                guard let self else { return }
                cropAdjustment = lastVideoCrop.map { Crop.relative(rect, to: $0) }
                self.capture?.setCrop(rect)
            }
        }
    }

    private func showCrop(_ image: CGImage, still: Bool = false, onSelect: @escaping (CGRect) -> Void) {
        cropWindow?.close()
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 640)
        let scale = min(screen.width * 0.84 / Double(image.width), screen.height * 0.80 / Double(image.height), 1)
        let size = NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = still ? "Sabitlemek istediğiniz alanı sürükleyerek seçin" : "Yalnızca video görüntüsünü sürükleyerek seçin"
        window.level = .floating
        let view = CropView(image: image)
        window.contentView = view
        view.onSelection = { [weak window] rect in
            window?.close()
            onSelect(rect)
        }
        cropWindow = window
        window.delegate = self
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showHelp() {
        alert("Kadraj nasıl kullanılır?", """
        • Video algılama menüsünden Safari, Chrome, Edge veya QuickTime’ı etkinleştirin. İlgili uygulamayı öne getirip videoyu oynatın.
        • Safari’de Geliştir → Apple Events’ten JavaScript’e İzin Ver ayarını açın. Chrome ve Edge’de bunun karşılığı Görünüm → Geliştirici menüsündedir.
        • Ekran kaydı ve Otomasyon isteklerine izin verin. Diğer oynatıcılarda Videoyu yakala seçeneğiyle başlayın.
        • Fare Kadraj’ın üzerine gelince alttaki pencereyi kullanırsınız. ⌘ basılıyken düğmeler açılır. Saydamlığı ve ⌘ ipucunu Kadraj menüsündeki Ayarlar’dan değiştirebilirsiniz.
        • Klavyedeki oynat/duraklat medya tuşu, macOS’un seçtiği etkin oynatıcıyı yönetir.
        • Video bulununca menü çubuğu simgesi turuncu olur. Safari otomasyonu kullanılamıyorsa menüden Erişilebilirlik ile algılamayı açabilirsiniz.
        • Safari uzantısını etkinleştirdikten sonra Kadraj menüsünden Safari’ye bağlan’ı seçin.
        • Yansıtılan kaynak değişirse son kare ekranda kalır. Tek bir görüntüyü saklamak için Görüntüyü sabitle seçeneğini kullanın.
        """)
    }

    private func showScreenPermission() {
        alert("Ekran kaydı izni gerekli",
              "Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı bölümünde Kadraj’a izin verin. Gerekirse Kadraj’ı yeniden açın.")
    }

    private func alert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Tamam")
        NSApp.activate()
        alert.runModal()
    }

    func checkMenuAndPlayer() throws {
        let json = Data(#"{"id":"test","title":"Test videosu","paused":false,"rect":[0,0,1,1]}"#.utf8)
        let media = try JSONDecoder().decode(Media.self, from: json)
        rebuildMenu()
        assert(status.button?.toolTip == "Kadraj")
        assert(status.menu?.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil } == true)
        let settings = status.menu?.item(withTitle: "Ayarlar")?.submenu
        assert(settings?.items.first { $0.action == #selector(toggleCommandHint) }?.state == .on)
        assert(settings?.items.contains { $0.action == #selector(editTransparency) } == true)
        assert(settings?.item(withTitle: "Klavye kısayolları")?.submenu?.items.map(\.tag) == [1, 3])
        assert(status.menu?.item(withTitle: "Yakalama")?.submenu?.items.count == 3)
        showOffer(.browser(.safari, media), subtitle: "Yerel test")
        assert(status.button?.toolTip?.contains("Video bulundu") == true)
        assert(status.button?.image?.isTemplate == false)
        assert(status.menu?.items.contains { $0.action == #selector(acceptOffer) } == true)
        RunLoop.main.run(until: Date().addingTimeInterval(5.2))
        assert(offerPanel == nil && status.button?.toolTip == "Kadraj" && pendingOffer != nil)
        dismissOffer()
        assert(status.button?.toolTip == "Kadraj")

        guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                      bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let frame = context.makeImage() else { preconditionFailure("Could not create a test frame") }
        displayFrame(frame)
        assert(player.isVisible)
        toggleVisibility()
        displayFrame(frame)
        assert(!player.isVisible && hiddenByUser)
        toggleVisibility()
        assert(player.isVisible && !hiddenByUser)
        closePlayer()
        assert(!player.isVisible && !hasPicture)

        let sourceID = UUID()
        safariBridge.frameVideo = sourceID
        safariFramePaused = true
        displayFrame(frame)
        safariSourceLost(UUID())
        assert(player.isVisible)
        safariSourceLost(sourceID)
        assert(!player.isVisible && safariBridge.frameVideo == nil)

        safariBridge.frameVideo = sourceID
        displayFrame(frame)
        togglePictureFreeze()
        displayFrame(frame)
        assert(livePictureFrozen && latestLiveFrame != nil && safariBridge.frameVideo == sourceID)
        togglePictureFreeze()
        assert(!livePictureFrozen && latestLiveFrame == nil && safariBridge.frameVideo == sourceID)
        togglePictureFreeze()
        safariSourceLost(sourceID)
        assert(player.isVisible && pictureFrozen)
        togglePictureFreeze()
        assert(!player.isVisible && !pictureFrozen)

        let direct = AVPlayer()
        nativePlayer = direct
        bindMediaKeys(to: direct)
        updateNowPlaying(direct)
        assert(mediaKeyTargets.count == 3 && mediaKeyTargets.allSatisfy { $0.0.isEnabled })
        assert(nowPlayingState == .paused)
        assert(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Kadraj")
        toggleVisibility()
        assert(mediaKeyTargets.count == 3)
        closePlayer()
        assert(mediaKeyTargets.isEmpty && nowPlayingState == .stopped)
        assert(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc func toggleAspectLock() { player.toggleAspectLock() }
}

extension AppController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === cropWindow { cropWindow = nil }
    }
}
