import AVFoundation

@MainActor
enum NativePlayback {
    static func prepare(_ url: URL, allowLive: Bool = false, while isCurrent: () -> Bool) async -> AVPlayer? {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while isCurrent(), ContinuousClock.now < deadline, !Task.isCancelled {
            if item.status == .failed { break }
            if item.status == .readyToPlay, item.presentationSize.width > 0, item.presentationSize.height > 0,
               (allowLive || (item.duration.seconds.isFinite && item.duration.seconds > 0)) {
                return player
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        player.replaceCurrentItem(with: nil)
        return nil
    }

    static func position(_ time: Double, duration: Double) -> CMTime {
        let end = duration.isFinite ? max(0, duration) : .greatestFiniteMagnitude
        return CMTime(seconds: min(max(0, time.isFinite ? time : 0), end), preferredTimescale: 600)
    }

    static func seek(_ player: AVPlayer, to time: Double) async -> Bool {
        let target = position(time, duration: player.currentItem?.duration.seconds ?? 0)
        return await withCheckedContinuation { continuation in
            let result = SeekResult(continuation)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                DispatchQueue.main.async { result.finish(finished) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak player] in
                if result.finish(false) { player?.currentItem?.cancelPendingSeeks() }
            }
        }
    }

    @MainActor
    private final class SeekResult {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        @discardableResult
        func finish(_ finished: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: finished)
            return true
        }
    }

    static func jump(_ player: AVPlayer, by delta: Double) {
        let current = player.currentTime()
        guard current.seconds.isFinite else { return }
        let range = player.currentItem?.seekableTimeRanges.map(\.timeRangeValue)
            .first { $0.containsTime(current) }
        if let range {
            let time = min(max(current.seconds + delta, range.start.seconds), range.end.seconds)
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        } else if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            player.seek(to: position(current.seconds + delta, duration: duration))
        }
    }

    static func canSeek(_ player: AVPlayer) -> Bool {
        player.currentItem?.seekableTimeRanges.isEmpty == false
    }
}
