import AppKit
import Foundation
import NDMCore

/// Shared display-progress hub keyed by download task.
///
/// Real engine progress is the target; observers receive a monotonic smoothed
/// display value so list rows, the hero card, progress window, and inspector
/// stay in sync without each inventing their own ease curve.
///
/// Main-thread only (UI surfaces + RunLoop timer).
final class SmoothProgressCenter {
    static let shared = SmoothProgressCenter()

    final class ObservationToken {
        private let id: UUID
        private let taskID: Int64
        private weak var center: SmoothProgressCenter?
        private var cancelled = false

        fileprivate init(id: UUID, taskID: Int64, center: SmoothProgressCenter) {
            self.id = id
            self.taskID = taskID
            self.center = center
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            center?.removeObserver(id: id, taskID: taskID)
            center = nil
        }
    }

    private final class Entry {
        var tracker: SmoothProgressTracker
        var observers: [UUID: (Double) -> Void] = [:]

        init(seed: Double) {
            tracker = SmoothProgressTracker(seed: seed)
        }
    }

    private var entries: [Int64: Entry] = [:]
    private var timer: Timer?
    private var lastTickUptime: TimeInterval = 0

    private init() {}

    /// Current smoothed display for a task.
    func display(for taskID: Int64, fallback: Double = 0) -> Double {
        assert(Thread.isMainThread)
        return entries[taskID]?.tracker.display ?? min(1, max(0, fallback))
    }

    /// Publish a truthful progress sample. Returns the current display value.
    @discardableResult
    func setTarget(
        taskID: Int64,
        _ target: Double,
        complete: Bool = false,
        reset: Bool = false
    ) -> Double {
        assert(Thread.isMainThread)
        let entry: Entry
        if let existing = entries[taskID] {
            entry = existing
            if reset {
                entry.tracker.reset(to: target)
            }
        } else {
            entry = Entry(seed: target)
            entries[taskID] = entry
        }
        if !reset {
            entry.tracker.setTarget(target, complete: complete)
        } else if complete {
            entry.tracker.setTarget(1, complete: true)
        }
        if !entry.tracker.isSettled {
            ensureTimer()
        }
        return entry.tracker.display
    }

    /// Observe display updates for one task. Invokes `handler` immediately,
    /// then on every animation tick while chasing.
    func observe(
        taskID: Int64,
        seed: Double = 0,
        _ handler: @escaping (Double) -> Void
    ) -> ObservationToken {
        assert(Thread.isMainThread)
        let entry: Entry
        if let existing = entries[taskID] {
            entry = existing
        } else {
            entry = Entry(seed: seed)
            entries[taskID] = entry
        }
        let id = UUID()
        entry.observers[id] = handler
        handler(entry.tracker.display)
        if !entry.tracker.isSettled {
            ensureTimer()
        }
        return ObservationToken(id: id, taskID: taskID, center: self)
    }

    func removeTask(_ taskID: Int64) {
        assert(Thread.isMainThread)
        entries.removeValue(forKey: taskID)
        if entries.isEmpty {
            stopTimer()
        }
    }

    fileprivate func removeObserver(id: UUID, taskID: Int64) {
        assert(Thread.isMainThread)
        guard let entry = entries[taskID] else { return }
        entry.observers.removeValue(forKey: id)
        if entry.observers.isEmpty, entry.tracker.isSettled {
            entries.removeValue(forKey: taskID)
        }
        if entries.isEmpty {
            stopTimer()
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - lastTickUptime))
        lastTickUptime = now
        guard dt > 0 else { return }

        var anyActive = false
        for entry in entries.values {
            if entry.tracker.isSettled { continue }
            anyActive = true
            let value = entry.tracker.advance(by: dt)
            // Copy handlers in case a callback cancels its token.
            let handlers = Array(entry.observers.values)
            for handler in handlers {
                handler(value)
            }
        }
        if !anyActive {
            stopTimer()
        }
    }
}
