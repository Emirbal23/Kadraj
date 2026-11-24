import AppKit
import AVFoundation

if CommandLine.arguments.contains("--self-check") {
    assert(abs(Crop.validated(CGRect(x: -0.2, y: 0.2, width: 0.5, height: 0.4)).width - 0.3) < 0.0001)
    assert(Crop.validated(CGRect(x: 1.1, y: 0, width: 0.5, height: 0.5)).isEmpty)
    assert(Crop.pixels(CGRect(x: 0.25, y: 0.10, width: 0.5, height: 0.40),
                       in: CGRect(x: 0, y: 0, width: 400, height: 200))
           == CGRect(x: 100, y: 100, width: 200, height: 80))
    let surface = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    assert(Crop.frameExtent(CGRect(x: 10, y: 20, width: 640, height: 360), scale: 2, in: surface)
           == CGRect(x: 20, y: 240, width: 1280, height: 720))
    let video = CGRect(x: 0.2, y: 0.2, width: 0.50, height: 0.50)
    let selection = CGRect(x: 0.25, y: 0.30, width: 0.30, height: 0.25)
    let moved = CGRect(x: 0.1, y: 0.1, width: 0.75, height: 0.75)
    let adjusted = Crop.applying(Crop.relative(selection, to: video), to: moved)
    assert(abs(adjusted.minX - 0.175) < 0.0001 && abs(adjusted.minY - 0.25) < 0.0001)
    assert(abs(adjusted.width - 0.45) < 0.0001 && abs(adjusted.height - 0.375) < 0.0001)
    MainActor.assumeIsolated {
        assert(NativePlayback.position(-10, duration: 120).seconds == 0)
        assert(NativePlayback.position(135, duration: 120).seconds == 120)
    }
    let surfaceBounds = CGRect(x: 0, y: 0, width: 240, height: 180)
    let mirror = try! JSONDecoder().decode(SafariMirrorGeometry.self,
        from: Data(#"{"window":[20,40,1000,650],"crop":[0.1,0.2,0.7,0.6],"title":"Video"}"#.utf8))
    assert(mirror.matches(frame: CGRect(x: 20, y: 40, width: 1000, height: 650), title: "Kişisel — Video"))
    assert(!mirror.matches(frame: CGRect(x: 20, y: 40, width: 1000, height: 650), title: "Başka sekme"))
    assert(!mirror.matches(frame: CGRect(x: 20, y: 40, width: 900, height: 650), title: "Video"))
    assert(abs(mirror.region.width - 0.7) < 0.0001)
    let original = WindowStamp(title: "A", frame: surfaceBounds)
    assert(original.sameContent(as: WindowStamp(title: "A", frame: surfaceBounds.offsetBy(dx: 10, dy: 15))))
    assert(!original.sameContent(as: WindowStamp(title: "B", frame: surfaceBounds)))
} else if CommandLine.arguments.contains("--check-automation") {
    let passed = MainActor.assumeIsolated { MediaProbe().checkScripts() }
    if !passed { exit(1) }
} else if CommandLine.arguments.contains("--check-window") {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let panel = PlayerPanel()
        panel.checkInteraction()
        assert(panel.styleMask.contains(.resizable))
        assert(PlayerPanel.timeLabel(72, duration: 754) == "1:12 / 12:34")
        assert(PlayerPanel.timeLabel(3650, duration: 7200) == "1:00:50 / 2:00:00")
        assert(PlayerPanel.timeLabel(5, duration: .infinity) == "Canlı")
        try! AppController().checkMenuAndPlayer()
        print("Menü simgeleri, video rozeti, medya komutu kaydı ve temizliği doğrulandı.")
        print("macOS panelinde saydamlık, tıklama geçişi, ⌘ ipucu ve pencere boyutu kontrolleri geçti.")
    }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
