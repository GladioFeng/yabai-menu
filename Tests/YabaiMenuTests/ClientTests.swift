// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import YabaiMenuKit

@MainActor
final class ClientTests: XCTestCase {
    @MainActor private final class FakeYabai {
        var commands: [[String]] = []
        var focusedSpace = 1
        var failQueries = false
        var signals = "[]"
        var failSignals = false
        var failFocus = false
        var holdSpace = false
        var holdRegistration = false
        var holdDisplay = false
        var releaseDisplay: CheckedContinuation<Void, Never>?
        var indices = [1, 2, 3, 4]
        var removed = Set<Int>()
        var failMutation = false
        var releaseSpace: CheckedContinuation<Void, Never>?
        var releaseRegistration: CheckedContinuation<Void, Never>?

        func run(_ path: String, _ args: [String]) async throws -> Data {
            commands.append(args)
            if args.contains("signal") {
                if args.contains("--remove") { return Data() }
                if failSignals { throw MenuError.message("signal unavailable") }
                if args.contains("--list") { return Data(signals.utf8) }
                if holdRegistration { await withCheckedContinuation { releaseRegistration = $0 } }
                return Data()
            }
            if args.contains("query") {
                if failQueries { throw MenuError.message("connection refused") }
                if args.contains("--windows") { return Data("[]".utf8) }
                if args.contains("--displays") { return Data("[{\"id\":101,\"index\":1,\"uuid\":\"test-display\"}]".utf8) }
                let spaces: [[String: Any]] = (1...4).filter { !removed.contains($0) }.map {
                    ["id": $0, "index": indices[$0 - 1], "display": 1, "label": "", "type": "bsp", "has-focus": $0 == focusedSpace, "is-visible": $0 == focusedSpace]
                }
                return try JSONSerialization.data(withJSONObject: spaces)
            }
            if args.contains("--label") || args.contains("--create") || args.contains("--destroy") || args.contains("--swap") {
                if failMutation { throw MenuError.message("mutation unavailable") }
            }
            if args[1] == "display", holdDisplay { await withCheckedContinuation { releaseDisplay = $0 }; holdDisplay = false }
            if args.contains("--focus") {
                if failFocus { throw MenuError.message("focus unavailable") }
                if args[1] == "space" {
                    if holdSpace { await withCheckedContinuation { releaseSpace = $0 }; holdSpace = false }
                    if focusedSpace == Int(args.last!) { throw MenuError.alreadyFocusedSpace }
                    focusedSpace = Int(args.last!)!
                }
            }
            return Data()
        }
    }

    private func makeClient(_ fake: FakeYabai, register: YabaiClient.Register? = nil) -> YabaiClient {
        YabaiClient(path: "/fake/yabai", notification: "test.yabai-menu.\(UUID().uuidString)", run: fake.run, register: register, windowEvents: YabaiWindowEvents(trusted: { false }, supportsTitles: true))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date(timeIntervalSinceNow: 2)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testLatestSelectionWinsInsteadOfBeingDropped() async {
        let fake = FakeYabai()
        let active = makeClient(fake)
        active.start(observeSystem: false)
        await waitUntil { active.status.mode == .live }
        fake.holdSpace = true
        active.focus(space: 2, window: 21)
        await waitUntil { fake.releaseSpace != nil }
        active.focus(space: 3, window: 31)
        active.focus(space: 4, window: 41)
        fake.releaseSpace?.resume()
        await waitUntil { !active.status.isSwitching }
        XCTAssertEqual(fake.commands.filter { $0.contains("--focus") }, [
            ["-m", "space", "--focus", "2"], ["-m", "space", "--focus", "4"], ["-m", "window", "--focus", "41"]])
        await active.stop()
    }

    func testActionFailureIsNotClearedBySuccessfulRefresh() async {
        let fake = FakeYabai()
        let active = makeClient(fake)
        active.start(observeSystem: false)
        await waitUntil { active.status.mode == .live }
        fake.failFocus = true
        active.focus(space: 2, window: nil)
        await waitUntil { active.status.actionError != nil }
        let error = active.status.actionError
        let before = active.status.lastUpdated
        active.refresh()
        await waitUntil { active.status.lastUpdated != before }
        XCTAssertEqual(active.status.actionError, error)
        active.dismissActionError()
        XCTAssertNil(active.status.actionError)
        await active.stop()
    }

    func testStaleSnapshotCannotSuppressSpaceSelectionAndSameSpaceAllowsWindowFocus() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        XCTAssertEqual(client.snapshot?.focusedSpace?.index, 1)
        fake.focusedSpace = 2
        client.focus(space: 1, window: nil)
        await waitUntil { !client.status.isSwitching }
        XCTAssertEqual(fake.focusedSpace, 1)
        client.focus(space: 1, window: 11)
        await waitUntil { !client.status.isSwitching }
        XCTAssertTrue(fake.commands.contains(["-m", "window", "--focus", "11"]))
        XCTAssertNil(client.status.actionError)
        await client.stop()
    }

    func testRegistrationFailureAndNotificationFailureAreVisible() async {
        let fake = FakeYabai()
        fake.failSignals = true
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.snapshot != nil }
        XCTAssertEqual(client.status.mode, .limited)
        XCTAssertTrue(client.status.detail?.contains("registration") == true)
        fake.failSignals = false
        client.reconnect(force: true)
        await waitUntil { client.status.mode == .live }
        await client.stop()

        let rejected = makeClient(FakeYabai(), register: { _, _ in nil })
        rejected.start(observeSystem: false)
        await waitUntil { rejected.snapshot != nil }
        XCTAssertEqual(rejected.status.mode, .limited)
        XCTAssertTrue(rejected.status.detail?.contains("notifications") == true)
        await rejected.stop()
    }

    func testFailedQueryKeepsSnapshotAndRecoversOnNextEvent() async {
        let fake = FakeYabai()
        let active = makeClient(fake)
        active.start(observeSystem: false)
        await waitUntil { active.status.mode == .live }
        let snapshot = active.snapshot
        fake.failQueries = true
        active.refresh()
        await waitUntil { active.status.mode == .disconnected }
        XCTAssertEqual(active.snapshot, snapshot)
        fake.failQueries = false
        active.scheduleRefresh()
        await waitUntil { active.status.mode == .live }
        await active.stop()
    }

    func testBurstEventsCoalesceAndIdleDoesNotPoll() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        let before = fake.commands.count
        for _ in 0..<100 { client.scheduleRefresh() }
        await waitUntil { fake.commands.count >= before + 3 }
        XCTAssertEqual(fake.commands.count, before + 3)
        let idle = fake.commands.count
        try? await Task.sleep(nanoseconds: 5_300_000_000)
        XCTAssertEqual(fake.commands.count, idle, "No five-second query or signal heartbeat is allowed")
        await client.stop()
    }

    func testNativeMoveBurstUsesABarTrailingDelay() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        let before = fake.commands.filter { $0.contains("--windows") }.count
        for _ in 0..<4 {
            client.scheduleMoveRefresh()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(fake.commands.filter { $0.contains("--windows") }.count, before)
        await waitUntil { fake.commands.filter { $0.contains("--windows") }.count > before }
        XCTAssertEqual(fake.commands.filter { $0.contains("--windows") }.count, before + 1)
        XCTAssertFalse(fake.commands.contains { $0.contains("event=window_moved") || $0.contains("event=window_resized") || $0.contains("event=window_title_changed") })
        client.scheduleMoveRefresh()
        await client.stop()
        let stopped = fake.commands.count
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(fake.commands.count, stopped)
    }

    func testStopDuringRegistrationCannotAddLateSignals() async {
        let fake = FakeYabai()
        fake.holdRegistration = true
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { fake.releaseRegistration != nil }
        let stop = Task { await client.stop() }
        await Task.yield()
        fake.releaseRegistration?.resume()
        await stop.value
        XCTAssertEqual(fake.commands.filter { $0.contains("--add") }.count, 1)
        XCTAssertEqual(fake.commands.filter { $0.contains("--remove") }.count, YabaiClient.ownedEvents.count)
        XCTAssertFalse(fake.commands.contains { $0.contains("query") })
    }

    func testFullRefreshReadsDisplayFocusAndRetiresOldHotSignals() async {
        let fake = FakeYabai()
        fake.signals = #"[{"label":"yabai-menu-window_moved","event":"window_moved","action":"old"},{"label":"yabai-menu-window_resized","event":"window_resized","action":"old"},{"label":"yabai-menu-window_title_changed","event":"window_title_changed","action":"old"},{"label":"other-window_moved","event":"window_moved","action":"leave-alone"}]"#
        var callbacks: [String: () -> Void] = [:]
        let client = makeClient(fake, register: { name, callback in callbacks[name] = callback; return 0 })
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        XCTAssertEqual(fake.commands.filter { $0.contains("--remove") }.map { $0.last! }, ["yabai-menu-window_moved", "yabai-menu-window_resized", "yabai-menu-window_title_changed"])
        XCTAssertEqual(fake.commands.filter { $0.contains("--displays") }.count, 1)
        XCTAssertTrue(fake.commands.contains(["-m", "query", "--displays", YabaiClient.displayFields]))
        XCTAssertTrue(fake.commands.contains(["-m", "query", "--spaces", YabaiClient.spaceFields]))
        XCTAssertTrue(fake.commands.contains(["-m", "query", "--windows", YabaiClient.windowFields]))
        let previous = client.status.lastUpdated
        client.refresh()
        await waitUntil { client.status.lastUpdated != previous }
        XCTAssertEqual(fake.commands.filter { $0.contains("--displays") }.count, 2)
        let topology = callbacks.first { $0.key.hasSuffix(".displays") }?.value
        XCTAssertNotNil(topology)
        topology?()
        await waitUntil { fake.commands.filter { $0.contains("--displays") }.count == 3 }
        await waitUntil { client.status.mode == .live }
        XCTAssertFalse(fake.commands.contains { $0.contains("other-window_moved") })
        XCTAssertTrue(fake.commands.filter { $0.contains("--add") && $0.contains("event=display_added") }
            .allSatisfy { $0.contains { $0.hasPrefix("action=") && $0.hasSuffix(".displays") } })
        await client.stop()
    }

    func testDaemonRestartReinstallsEventsWithoutAHeartbeat() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        client.daemonChanged(available: false)
        XCTAssertEqual(client.status.mode, .disconnected)
        let before = fake.commands.filter { $0.contains("--add") }.count
        client.daemonChanged(available: true)
        await waitUntil { client.status.mode == .live }
        XCTAssertEqual(fake.commands.filter { $0.contains("--add") }.count, before + YabaiClient.events.count)
        await client.stop()
    }

    func testRestartDuringFocusDoesNotSendAnOldWindowCommand() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        fake.holdSpace = true
        client.focus(space: 2, window: 21)
        await waitUntil { fake.releaseSpace != nil }
        client.daemonChanged(available: false)
        fake.releaseSpace?.resume()
        await waitUntil { !client.status.isSwitching }
        XCTAssertFalse(fake.commands.contains(["-m", "window", "--focus", "21"]))
        XCTAssertNil(client.status.actionError)
        await client.stop()
    }

    func testScreenSleepPausesQueriesUntilWakeEvent() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        client.screenChanged(sleeping: true)
        XCTAssertEqual(client.status.mode, .suspended)
        let count = fake.commands.count
        client.refresh()
        client.scheduleRefresh()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(fake.commands.count, count)
        client.screenChanged(sleeping: false)
        await waitUntil { client.status.mode == .live }
        XCTAssertGreaterThan(fake.commands.count, count)
        await client.stop()
    }

    func testPermanentFailuresExhaustBoundedRetries() async {
        for queryFailure in [false, true] {
            let fake = FakeYabai()
            fake.failQueries = queryFailure
            fake.failSignals = !queryFailure
            let client = makeClient(fake)
            client.start(observeSystem: false)
            try? await Task.sleep(nanoseconds: 7_500_000_000)
            XCTAssertEqual(fake.commands.filter { $0.contains("--list") }.count, 4, "Initial attempt plus at most three retries")
            let count = fake.commands.count
            try? await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(fake.commands.count, count)
            await client.stop()
        }
    }

    func testDisplayTopologyRecoversWithoutAScreenWakeNotification() async {
        let fake = FakeYabai()
        var awake = false
        let client = YabaiClient(path: "/fake/yabai", notification: "test.yabai-menu.\(UUID().uuidString)",
                                 run: fake.run, displaysAwake: { awake })
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        client.displayConfigurationChanged()
        XCTAssertEqual(client.status.mode, .suspended)
        let before = fake.commands.count
        client.refresh()
        XCTAssertEqual(fake.commands.count, before)
        awake = true
        client.displayConfigurationChanged()
        await waitUntil { client.status.mode == .live }
        XCTAssertGreaterThan(fake.commands.count, before)
        await client.stop()
    }
    func testMutationsStayFIFOAndResolveStableIDsAfterDisplayFocus() async {
        let fake = FakeYabai()
        let active = makeClient(fake)
        active.start(observeSystem: false)
        await waitUntil { active.status.mode == .live }
        fake.holdDisplay = true
        active.perform(.remove(spaceID: 2))
        await waitUntil { fake.releaseDisplay != nil }
        active.perform(.rename(spaceID: 3, label: #"工作 ' "quoted""#))
        active.focus(space: 1, window: 10)
        active.focus(space: 4, window: 40)
        active.perform(.move(spaceID: 3, offset: -1))
        fake.indices = [1, 4, 3, 2]
        fake.releaseDisplay?.resume()
        await waitUntil { !active.status.isSwitching }
        let commands = fake.commands.filter { !$0.contains("query") && !$0.contains("signal") }
        XCTAssertEqual(commands, [
            ["-m", "display", "--focus", "1"], ["-m", "space", "4", "--destroy"],
            ["-m", "space", "3", "--label", #"工作 ' "quoted""#],
            ["-m", "space", "--focus", "2"], ["-m", "window", "--focus", "40"],
            ["-m", "space", "3", "--swap", "2"]])
        await active.stop()
    }

    func testVanishedSpaceAndStoppedMultiStepActionNeverMutateWrongTarget() async {
        for stopEarly in [false, true] {
            let fake = FakeYabai()
            let client = makeClient(fake)
            client.start(observeSystem: false)
            await waitUntil { client.status.mode == .live }
            fake.holdDisplay = true
            client.perform(.remove(spaceID: 2))
            await waitUntil { fake.releaseDisplay != nil }
            client.perform(.create(anchorID: 1))
            fake.removed.insert(2)
            let stop: Task<Void, Never>? = stopEarly ? Task { await client.stop() } : nil
            if stopEarly { await Task.yield() }
            fake.releaseDisplay?.resume()
            if let stop { await stop.value }
            else { await waitUntil { !client.status.isSwitching }; XCTAssertNotNil(client.status.actionError); await client.stop() }
            XCTAssertFalse(fake.commands.contains { $0.contains("--destroy") })
            if stopEarly { XCTAssertFalse(fake.commands.contains { $0.contains("--create") }) }
        }
    }

    func testFailedMutationRefreshesWithoutRetryAndDisconnectedRejectsActions() async {
        let fake = FakeYabai()
        let active = makeClient(fake)
        active.perform(.create(anchorID: 1))
        XCTAssertTrue(fake.commands.isEmpty)
        active.start(observeSystem: false)
        await waitUntil { active.status.mode == .live }
        fake.failMutation = true
        let previous = active.status.lastUpdated
        active.perform(.create(anchorID: 1))
        await waitUntil { active.status.actionError != nil && active.status.lastUpdated != previous }
        XCTAssertEqual(fake.commands.filter { $0.contains("--create") }.count, 1)
        active.screenChanged(sleeping: true)
        let count = fake.commands.count
        active.perform(.rename(spaceID: 1, label: "ignored"))
        XCTAssertEqual(fake.commands.count, count)
        await active.stop()
    }

    func testCreateAndRemoveContinueWhenDisplayIsAlreadyFocused() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: executable) }
        try Data("#!/bin/sh\nprintf 'cannot focus an already focused display.\\n' >&2\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let fake = FakeYabai()
        let client = YabaiClient(path: "/fake/yabai", notification: "test.yabai-menu.\(UUID().uuidString)", run: { path, arguments in
            if arguments.starts(with: ["-m", "display", "--focus"]) {
                return try await Command.run(executable.path, arguments)
            }
            return try await fake.run(path, arguments)
        })
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        client.perform(.create(anchorID: 1))
        client.perform(.remove(spaceID: 2))
        await waitUntil { !client.status.isSwitching }
        XCTAssertTrue(fake.commands.contains(["-m", "space", "--create"]))
        XCTAssertTrue(fake.commands.contains(["-m", "space", "2", "--destroy"]))
        XCTAssertNil(client.status.actionError)
        await client.stop()

        do {
            _ = try await Command.run(executable.path, ["-m", "window", "--focus", "1"])
            XCTFail("An unrelated command with the same diagnostic must still fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Command failed")) }
        try Data("#!/bin/sh\nprintf 'cannot focus an already focused display.\\n' >&2\nexit 2\n".utf8).write(to: executable)
        do {
            _ = try await Command.run(executable.path, ["-m", "display", "--focus", "1"])
            XCTFail("Only the exact known status-1 diagnostic can be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Command failed")) }
        try Data("#!/bin/sh\nprintf 'cannot focus an already focused display.\\npermission denied\\n' >&2\nexit 1\n".utf8).write(to: executable)
        do {
            _ = try await Command.run(executable.path, ["-m", "display", "--focus", "1"])
            XCTFail("Additional diagnostics must not be swallowed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("permission denied")) }
    }

}
