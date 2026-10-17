import AppKit
import Combine

/// A countdown timer started from the expanded island.
final class CountdownTimer: ObservableObject {
    /// Time left in whole seconds: the island redraws once a second, not on every tick.
    @Published private(set) var seconds = 0
    @Published private(set) var isActive = false
    @Published private(set) var isRunning = false

    var onFinish: (() -> Void)?
    private var endDate = Date()
    private var ticker: Timer?

    func start(minutes: Int) {
        seconds = minutes * 60
        isActive = true
        resume()
    }

    func togglePause() {
        guard isActive else { return }
        if isRunning {
            ticker?.invalidate()
            ticker = nil
            isRunning = false
        } else {
            resume()
        }
    }

    func add(minutes: Int) {
        guard isActive else { return }
        seconds += minutes * 60
        endDate.addTimeInterval(TimeInterval(minutes * 60))
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        isActive = false
        seconds = 0
    }

    private func resume() {
        endDate = Date().addingTimeInterval(TimeInterval(seconds))
        isRunning = true
        ticker?.invalidate()
        let ticker = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        ticker.tolerance = 0.1
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func tick() {
        let left = endDate.timeIntervalSinceNow
        guard left > 0 else {
            cancel()
            NSSound(named: "Glass")?.play()
            onFinish?()
            return
        }
        let whole = Int(left.rounded(.up))
        if whole != seconds { seconds = whole }
    }
}
