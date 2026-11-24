import WebKit

@MainActor
final class YouTubePlayback {
    let view: WKWebView
    private(set) var time = 0.0
    private(set) var duration: Double?
    private(set) var playing = false
    private(set) var errorCode: Int?
    private var state = -1
    private var startDeadline: ContinuousClock.Instant?
    private var live = false

    init?(id: String) {
        guard id.range(of: #"^[A-Za-z0-9_-]{11}\z"#, options: .regularExpression) != nil else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 250), configuration: config)
        let origin = "https://" + (Bundle.main.bundleIdentifier ?? "app.kadraj.macos")
        view.loadHTMLString("""
        <!doctype html>
        <html><head><meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body,#player { width:100%; height:100%; margin:0; background:#000; border:0; overflow:hidden; }</style>
        </head><body><div id="player"></div><script>
        let player, ready = false, error = null;
        function onYouTubeIframeAPIReady() {
          player = new YT.Player("player", {
            videoId: "\(id)",
            playerVars: {origin: "\(origin)", playsinline: 1},
            events: {
              onReady: () => { ready = true; },
              onError: event => { error = event.data; },
              onAutoplayBlocked: () => { error = -2; }
            }
          });
        }
        function kadrajSnapshot() {
          return {
            error, state: ready ? player.getPlayerState() : -1,
            time: ready ? player.getCurrentTime() : 0,
            duration: ready ? player.getDuration() : 0
          };
        }
        function kadrajStart(time, volume, play) {
          player.setVolume(volume);
          if (volume === 0) player.mute();
          const video = {videoId: "\(id)", startSeconds: time};
          if (play) player.loadVideoById(video);
          else player.cueVideoById(video);
        }
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """, baseURL: URL(string: origin + "/"))
    }

    func prepare(while isCurrent: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while isCurrent(), ContinuousClock.now < deadline, errorCode == nil {
            await refresh()
            if errorCode == nil, state == 5 { return isCurrent() }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    func start(time: Double, duration: Double?, volume: Double, playing: Bool) {
        self.time = time.isFinite ? max(0, time) : 0
        self.duration = duration
        live = duration == nil
        self.playing = playing
        if playing { startDeadline = ContinuousClock.now.advanced(by: .seconds(20)) }
        let volume = volume.isFinite ? max(0, min(100, volume * 100)) : 100
        view.evaluateJavaScript("kadrajStart(\(self.time), \(volume), \(playing))")
    }

    func setPlaying(_ play: Bool) {
        playing = play
        startDeadline = play && state == 5 ? ContinuousClock.now.advanced(by: .seconds(20)) : nil
        view.evaluateJavaScript(play ? "player.playVideo()" : "player.pauseVideo()")
    }

    func seek(by delta: Double) {
        guard let duration else { return }
        let position = min(duration, max(0, time + delta))
        time = position
        view.evaluateJavaScript("player.seekTo(\(position), true)")
    }

    func refresh() async {
        if let value = try? await view.evaluateJavaScript("kadrajSnapshot()") as? [String: Any] {
            errorCode = value["error"] as? Int
            state = value["state"] as? Int ?? -1
            if state == 1 { startDeadline = nil }
            if startDeadline == nil {
                playing = state == 1 || state == 3
            }
            if let position = value["time"] as? Double, position.isFinite, position >= 0,
               state == 1 || state == 2 || state == 0 {
                time = position
            }
            if !live, let total = value["duration"] as? Double, total.isFinite, total > 0 {
                duration = total
            }
        }
        if let deadline = startDeadline, ContinuousClock.now >= deadline {
            errorCode = errorCode ?? -1
        }
    }
}
