// Idle-timeout self-termination (decision 0015).
//
// The engine is launched on demand by whichever TSF client needs it first and
// is expected to go away again once nothing is using it — an IME that keeps a
// converter (and, with Zenzai, a loaded model) resident forever is a poor guest
// on the user's machine.
//
// This type owns the "is anything using us?" question. It is deliberately free
// of Windows and of `exit` itself: what to do on expiry is the caller's, which
// also makes the countdown testable without waiting in real time.

import Foundation

public final class IdleWatchdog: @unchecked Sendable {
    /// Runs `work` after `delay`. Injectable so tests can drive the clock.
    public typealias Scheduler = @Sendable (
        _ delay: TimeInterval,
        _ work: @escaping @Sendable () -> Void
    ) -> Void

    private let lock = NSLock()
    private var connectionCount = 0
    /// Bumped whenever a pending deadline stops being meaningful. A callback
    /// that arrives with a stale generation is a leftover from a countdown that
    /// has since been cancelled — Dispatch has no way to un-schedule work, so
    /// the callback has to recognize itself as obsolete.
    private var generation: UInt64 = 0
    private var hasExpired = false

    private let timeout: TimeInterval
    private let schedule: Scheduler
    private let onExpiry: @Sendable () -> Void

    /// - Parameter timeout: idle seconds before expiry. Zero or negative
    ///   disables the watchdog entirely, which is how a user who would rather
    ///   pay the memory than the first-conversion latency turns it off.
    public init(
        timeout: TimeInterval,
        schedule: @escaping Scheduler = IdleWatchdog.dispatchAfter,
        onExpiry: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.schedule = schedule
        self.onExpiry = onExpiry
    }

    /// Starts the initial countdown.
    ///
    /// Called at startup, before any client has connected: the process that
    /// launched us may die before it manages to connect, and without this the
    /// engine would sit there forever having served nobody.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        scheduleCountdownLocked()
    }

    public func connectionOpened() {
        lock.lock()
        defer { lock.unlock() }
        connectionCount += 1
        // Invalidate any countdown in flight; we are no longer idle.
        generation &+= 1
    }

    public func connectionClosed() {
        lock.lock()
        defer { lock.unlock() }
        connectionCount = max(0, connectionCount - 1)
        guard connectionCount == 0 else { return }
        scheduleCountdownLocked()
    }

    private func scheduleCountdownLocked() {
        guard timeout > 0 else { return }
        generation &+= 1
        let deadlineGeneration = generation
        schedule(timeout) { [weak self] in
            self?.deadlineReached(deadlineGeneration)
        }
    }

    private func deadlineReached(_ deadlineGeneration: UInt64) {
        lock.lock()
        let shouldExpire =
            deadlineGeneration == generation
            && connectionCount == 0
            && !hasExpired
        if shouldExpire { hasExpired = true }
        lock.unlock()

        // Outside the lock: the caller's handler ends the process, and holding
        // a lock across that buys nothing but a way to deadlock.
        if shouldExpire { onExpiry() }
    }

    public static let dispatchAfter: Scheduler = { delay, work in
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
}
