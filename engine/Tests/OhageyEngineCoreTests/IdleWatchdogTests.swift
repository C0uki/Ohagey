// Tests for idle-timeout self-termination (decision 0015).
//
// Expiry ends the process, so the failure mode worth guarding against is
// exiting while a client is still there — an application would lose its IME
// mid-composition. The countdown is driven through an injected scheduler rather
// than real time, so these assert on the logic instead of on timing luck.

import XCTest
@testable import OhageyEngineCore

/// Collects scheduled work instead of running it, so a test decides when a
/// deadline is reached.
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    private(set) var requestedDelays: [TimeInterval] = []

    var schedule: IdleWatchdog.Scheduler {
        { [self] delay, work in
            lock.lock()
            requestedDelays.append(delay)
            pending.append(work)
            lock.unlock()
        }
    }

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Fires every deadline scheduled so far, including ones a later event has
    /// made obsolete — that is exactly the case the watchdog has to survive.
    func fireAll() {
        lock.lock()
        let work = pending
        pending = []
        lock.unlock()
        work.forEach { $0() }
    }
}

private final class ExpiryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var handler: @Sendable () -> Void {
        { [self] in
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class IdleWatchdogTests: XCTestCase {
    private func makeWatchdog(
        timeout: TimeInterval = 300,
        scheduler: ManualScheduler,
        expiry: ExpiryCounter
    ) -> IdleWatchdog {
        IdleWatchdog(timeout: timeout, schedule: scheduler.schedule, onExpiry: expiry.handler)
    }

    /// The client that launched the engine may die before it connects.
    func testExpiresWhenNobodyEverConnects() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.start()
        scheduler.fireAll()

        XCTAssertEqual(expiry.value, 1)
    }

    func testUsesTheConfiguredTimeout() {
        let scheduler = ManualScheduler()
        let watchdog = makeWatchdog(timeout: 42, scheduler: scheduler, expiry: ExpiryCounter())

        watchdog.start()

        XCTAssertEqual(scheduler.requestedDelays, [42])
    }

    /// The case that would cost a user their composition.
    func testDoesNotExpireWhileAClientIsConnected() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.start()
        watchdog.connectionOpened()
        scheduler.fireAll()

        XCTAssertEqual(expiry.value, 0)
    }

    /// Dispatch cannot un-schedule work, so the startup countdown still fires
    /// after a client has connected and gone. It must not double-count.
    func testStaleCountdownFromBeforeAConnectionIsIgnored() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.start()
        watchdog.connectionOpened()
        watchdog.connectionClosed()
        // Two deadlines are outstanding: the obsolete startup one and the one
        // armed by the disconnect.
        XCTAssertEqual(scheduler.scheduledCount, 2)
        scheduler.fireAll()

        XCTAssertEqual(expiry.value, 1)
    }

    func testExpiresAfterTheLastClientDisconnects() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.start()
        watchdog.connectionOpened()
        watchdog.connectionOpened()
        watchdog.connectionClosed()
        scheduler.fireAll()
        XCTAssertEqual(expiry.value, 0, "one client is still connected")

        watchdog.connectionClosed()
        scheduler.fireAll()
        XCTAssertEqual(expiry.value, 1)
    }

    /// A client connecting inside the countdown window has to call it off.
    func testReconnectBeforeTheDeadlineCancelsExpiry() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.start()
        watchdog.connectionOpened()
        watchdog.connectionClosed()
        watchdog.connectionOpened()
        scheduler.fireAll()

        XCTAssertEqual(expiry.value, 0)
    }

    /// Expiry ends the process; running the handler twice would mean exiting
    /// twice, or exiting from under an already-running shutdown.
    func testExpiresAtMostOnce() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.start()
        scheduler.fireAll()
        watchdog.connectionClosed()
        scheduler.fireAll()

        XCTAssertEqual(expiry.value, 1)
    }

    func testNonPositiveTimeoutDisablesTheWatchdog() {
        for timeout in [0.0, -1.0] {
            let scheduler = ManualScheduler()
            let expiry = ExpiryCounter()
            let watchdog = makeWatchdog(timeout: timeout, scheduler: scheduler, expiry: expiry)

            watchdog.start()
            watchdog.connectionOpened()
            watchdog.connectionClosed()
            scheduler.fireAll()

            XCTAssertEqual(scheduler.scheduledCount, 0, "timeout \(timeout)")
            XCTAssertEqual(expiry.value, 0, "timeout \(timeout)")
        }
    }

    /// Guards against an unbalanced close driving the count negative, which
    /// would leave a later real disconnect unable to reach zero and arm the
    /// countdown at all.
    func testUnbalancedCloseDoesNotStrandTheCount() {
        let scheduler = ManualScheduler()
        let expiry = ExpiryCounter()
        let watchdog = makeWatchdog(scheduler: scheduler, expiry: expiry)

        watchdog.connectionClosed()
        watchdog.connectionOpened()
        watchdog.connectionClosed()
        scheduler.fireAll()

        XCTAssertEqual(expiry.value, 1)
    }
}
