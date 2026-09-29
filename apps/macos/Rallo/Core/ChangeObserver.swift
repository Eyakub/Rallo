import Foundation
import notify

/// Wakes the app when state may have changed. Darwin notifications from the
/// CLI are hints only; a single 1 s timer re-reads the cheap revision counter
/// so missed signals are still reconciled. UI never polls independently.
final class ChangeObserver {
    private let changeSignal: String
    private let showSignal: String
    private let diagnosticsSignal: String
    private var tokens: [Int32] = []
    private var timer: Timer?

    var onPossibleChange: () -> Void = {}
    var onShowRequest: () -> Void = {}
    var onDiagnosticsRequest: () -> Void = {}

    init(dataDir: String) {
        changeSignal = changeSignalName(dataDir: dataDir)
        showSignal = showSignalName(dataDir: dataDir)
        diagnosticsSignal = diagnosticsSignalName(dataDir: dataDir)
    }

    func start() {
        register(changeSignal) { [weak self] in self?.onPossibleChange() }
        register(showSignal) { [weak self] in self?.onShowRequest() }
        register(diagnosticsSignal) { [weak self] in self?.onDiagnosticsRequest() }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.onPossibleChange() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tokens.forEach { notify_cancel($0) }
        tokens.removeAll()
    }

    private func register(_ name: String, handler: @escaping () -> Void) {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in handler() }
        if status == NOTIFY_STATUS_OK {
            tokens.append(token)
        } else {
            NSLog("Rallo: could not register for change signal (status %u)", status)
        }
    }
}
