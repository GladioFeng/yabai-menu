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
        var windows = "[]"
        var windowOwner: Int32?
        var nextTargetedWindowError: MenuError?
        var missionControlActive = false
        var activeSpaceUnavailable = false
        var spaceDisplays: [Int: Int] = [:]
        var holdWindowFocusQuery = false
        var releaseWindowFocusQuery: CheckedContinuation<Void, Never>?
        var holdSpaceQuery = false
        var releaseSpaceQuery: CheckedContinuation<Void, Never>?
        var releaseSignalList: CheckedContinuation<Void, Never>?
        var holdSignalList = false
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
                if args.contains("--list") {
                    if holdSignalList { await withCheckedContinuation { releaseSignalList = $0 } }
                    return Data(signals.utf8)
                }
                if holdRegistration { await withCheckedContinuation { releaseRegistration = $0 } }
                return Data()
            }
            if args.contains("query") {
                if failQueries { throw MenuError.message("connection refused") }
                if args == ["-m", "query", "--windows", "id,pid"], let windowOwner {
                    return try JSONSerialization.data(withJSONObject: [["id": 10, "pid": windowOwner]])
                }
                if args.count == 6, args[2] == "--windows", args[4] == "--window", let windowOwner, let id = Int(args[5]) {
                    if holdWindowFocusQuery {
                        holdWindowFocusQuery = false
                        await withCheckedContinuation { releaseWindowFocusQuery = $0 }
                    }
                    if let error = nextTargetedWindowError {
                        nextTargetedWindowError = nil
                        throw error
                    }
                    return try JSONSerialization.data(withJSONObject: ["id": id, "pid": windowOwner])
                }
                if args.contains("--windows") { return Data(windows.utf8) }
                if args.contains("--displays") { return Data("[{\"id\":101,\"index\":1,\"uuid\":\"test-display\"}]".utf8) }
                if args == ["-m", "query", "--spaces"], holdSpaceQuery {
                    holdSpaceQuery = false
                    await withCheckedContinuation { releaseSpaceQuery = $0 }
                }
                let spaces = (1...4).filter { !removed.contains($0) }.map { id -> [String: Any] in
                    let focused = id == focusedSpace
                    let display = spaceDisplays[id] ?? 1
                    let visible = focused || spaceDisplays[id] != nil
                    return ["id": id, "index": indices[id - 1], "display": display, "label": "",
                            "type": "bsp", "has-focus": focused, "is-visible": visible]
                }
                if args.last == "--space" {
                    guard !activeSpaceUnavailable, let active = spaces.first(where: { $0["id"] as? Int == focusedSpace }) else {
                        throw MenuError.activeSpaceUnavailable
                    }
                    return try JSONSerialization.data(withJSONObject: active)
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
                    if missionControlActive { throw MenuError.message("cannot focus space because mission-control is active.") }
                    if holdSpace { await withCheckedContinuation { releaseSpace = $0 }; holdSpace = false }
                    if focusedSpace == Int(args.last!) { throw MenuError.alreadyFocusedSpace }
                    focusedSpace = Int(args.last!)!
                }
            }
            return Data()
        }
    }

    private func makeClient(_ fake: FakeYabai, register: YabaiClient.Register? = nil,
                            tracksWindowTitles: Bool = true, leftButtonDown: @escaping () -> Bool = { false }) -> YabaiClient {
        // Fake displays must not depend on whether the physical test host is asleep.
        YabaiClient(path: "/fake/yabai", notification: "test.yabai-menu.\(UUID().uuidString)", run: fake.run, register: register,
                    windowEvents: YabaiWindowEvents(trusted: { false }, supportsTitles: true), displaysAwake: { true },
                    tracksWindowTitles: tracksWindowTitles, leftButtonDown: leftButtonDown)
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

    func testWindowSelectionRechecksPIDBeforeSendingFocus() async {
        let fake = FakeYabai()
        fake.windows = #"[{"id":10,"pid":123,"app":"Fixture","space":1,"has-focus":true,"is-floating":false,"is-sticky":false,"is-hidden":false,"is-minimized":false,"stack-index":0,"frame":{"x":0}}]"#
        fake.windowOwner = 456
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live && client.snapshot?.windows.first?.pid == 123 }

        client.focus(space: 2, window: 10, expectedPID: 123)
        await waitUntil { !client.status.isSwitching }
        XCTAssertFalse(fake.commands.contains { $0.contains("--focus") })
        XCTAssertNotNil(client.status.actionError)

        fake.windowOwner = 123
        client.focus(space: nil, window: 10, expectedPID: 123)
        await waitUntil { !client.status.isSwitching }
        XCTAssertEqual(Array(fake.commands.suffix(2)), [
            ["-m", "query", "--windows", "id,pid", "--window", "10"],
            ["-m", "window", "--focus", "10"]
        ])
        XCTAssertNil(client.status.actionError)

        fake.holdSpace = true
        client.focus(space: 2, window: 10, expectedPID: 123)
        await waitUntil { fake.releaseSpace != nil }
        fake.windowOwner = 456
        fake.releaseSpace?.resume()
        await waitUntil { !client.status.isSwitching }
        XCTAssertEqual(Array(fake.commands.suffix(3)), [
            ["-m", "query", "--windows", "id,pid"],
            ["-m", "space", "--focus", "2"],
            ["-m", "query", "--windows", "id,pid", "--window", "10"]
        ])
        XCTAssertNotNil(client.status.actionError)
        await client.stop()
    }

    private func makeVisibleWindowFixture() -> FakeYabai {
        let fake = FakeYabai()
        fake.windows = #"[{"id":10,"pid":123,"app":"Fixture","space":1,"display":1,"has-focus":false,"is-visible":true,"is-floating":false,"is-sticky":false,"is-hidden":false,"is-minimized":false,"stack-index":0,"frame":{"x":0}}]"#
        fake.windowOwner = 123
        return fake
    }

    func testCurrentSpaceUsesOneOwnerQueryAndKeepsTheSpaceFocusGuard() async {
        let fake = makeVisibleWindowFixture()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live && client.snapshot?.windows.first?.pid == 123 }
        fake.commands.removeAll()
        client.focus(space: 1, window: 10, expectedPID: 123)
        await waitUntil { !client.status.isSwitching }
        XCTAssertFalse(fake.commands.contains(["-m", "query", "--spaces"]))
        XCTAssertTrue(fake.commands.contains { $0.contains("--spaces") && $0.last == "--space" })
        XCTAssertEqual(fake.commands.filter { $0.contains("--window") }, [
            ["-m", "query", "--windows", "id,pid", "--window", "10"]
        ])
        XCTAssertEqual(fake.commands.filter { $0.contains("--focus") }, [
            ["-m", "space", "--focus", "1"], ["-m", "window", "--focus", "10"]
        ])
        XCTAssertNil(client.status.actionError)

        fake.commands.removeAll()
        fake.windowOwner = 456
        client.focus(space: 1, window: 10, expectedPID: 123)
        await waitUntil { !client.status.isSwitching }
        XCTAssertFalse(fake.commands.contains { $0.contains("--focus") })
        XCTAssertNotNil(client.status.actionError)
        await client.stop()
    }

    func testAnotherActiveDisplayStillRequiresExplicitSpaceFocus() async {
        for activeUnavailable in [false, true] {
            let fake = makeVisibleWindowFixture()
            fake.spaceDisplays = [1: 1, 2: 2]
            let client = makeClient(fake)
            client.start(observeSystem: false)
            await waitUntil { client.status.mode == .live }

            fake.focusedSpace = 2  // Space 1 remains visible, but its display is no longer active.
            fake.activeSpaceUnavailable = activeUnavailable
            fake.nextTargetedWindowError = .windowUnavailable
            fake.commands.removeAll()
            client.focus(space: 1, window: 10, expectedPID: 123)

            await waitUntil { !client.status.isSwitching }
            XCTAssertTrue(fake.commands.contains(["-m", "query", "--spaces"]))
            XCTAssertEqual(fake.commands.filter { $0.contains("--focus") }, [
                ["-m", "space", "--focus", "1"], ["-m", "window", "--focus", "10"]
            ])
            XCTAssertNil(client.status.actionError)
            await client.stop()
        }
    }

    func testCurrentSpaceCannotFocusAWindowDuringMissionControl() async {
        let fake = makeVisibleWindowFixture()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        fake.missionControlActive = true
        client.focus(space: 1, window: 10, expectedPID: 123)
        await waitUntil { !client.status.isSwitching }
        XCTAssertEqual(fake.commands.filter { $0.contains("--focus") }, [["-m", "space", "--focus", "1"]])
        XCTAssertTrue(client.status.actionError?.contains("mission-control") == true)
        await client.stop()
    }

    func testOwnerLookupTimeoutIsNotFollowedByASerialSpaceRetry() async {
        let fake = makeVisibleWindowFixture()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        fake.commands.removeAll()
        fake.nextTargetedWindowError = .message("Command timed out.")
        client.focus(space: 1, window: 10, expectedPID: 123)
        await waitUntil { !client.status.isSwitching }
        XCTAssertFalse(fake.commands.contains(["-m", "query", "--spaces"]))
        XCTAssertEqual(fake.commands.filter { $0.contains("--window") }.count, 1)
        XCTAssertFalse(fake.commands.contains { $0.contains("--focus") })
        XCTAssertTrue(client.status.actionError?.contains("timed out") == true)
        await client.stop()
    }

    func testNewFocusSupersedesWindowWaitingOnFastPathLookup() async {
        let fake = makeVisibleWindowFixture()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        fake.holdWindowFocusQuery = true
        client.focus(space: 1, window: 10, expectedPID: 123)
        await waitUntil {
            fake.releaseWindowFocusQuery != nil && fake.commands.contains { $0.contains("--spaces") && $0.last == "--space" }
        }
        client.focus(space: 2, window: nil)
        fake.releaseWindowFocusQuery?.resume()
        await waitUntil { !client.status.isSwitching }
        XCTAssertEqual(fake.commands.filter { $0.contains("--focus") }, [["-m", "space", "--focus", "2"]])
        await client.stop()
    }

    func testNewFocusSupersedesOldSelectionWaitingOnSpaceLookup() async {
        let fake = FakeYabai()
        let client = makeClient(fake)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        fake.holdSpaceQuery = true
        client.focus(space: 2, window: nil)
        await waitUntil { fake.releaseSpaceQuery != nil }
        client.focus(space: 3, window: nil)
        fake.releaseSpaceQuery?.resume()
        await waitUntil { !client.status.isSwitching }
        XCTAssertEqual(fake.commands.filter { $0.contains("--focus") }, [["-m", "space", "--focus", "3"]])
        await client.stop()
    }

    func testPostActionRefreshAndPublicationWaitForNewMouseHold() async throws {
        var held = false
        let fake = FakeYabai()
        let client = makeClient(fake, leftButtonDown: { held })
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        fake.holdSpace = true
        client.focus(space: 2, window: nil)
        await waitUntil { fake.releaseSpace != nil }
        var published = 0
        client.onUpdate = { _, _ in published += 1 }
        fake.commands.removeAll()
        held = true
        fake.releaseSpace?.resume()
        await waitUntil { !client.status.isSwitching }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fake.commands.contains { $0.contains("query") })
        XCTAssertEqual(published, 0)
        held = false
        client.resumeDeferredAfterMouseUp()
        await waitUntil { client.snapshot?.focusedSpace?.index == 2 && published > 0 }
        await client.stop()
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
        let client = makeClient(fake, tracksWindowTitles: false)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        let before = fake.commands.filter { $0.contains("--windows") }.count
        let topology = fake.commands.filter { $0.contains("--spaces") || $0.contains("--displays") }.count
        for _ in 0..<4 {
            for _ in 0..<20 { client.scheduleMoveRefresh() } // per-frame events within one burst
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertEqual(fake.commands.filter { $0.contains("--windows") }.count, before)
        await waitUntil { fake.commands.filter { $0.contains("--windows") }.count > before }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.commands.filter { $0.contains("--windows") }.count, before + 1)
        XCTAssertEqual(fake.commands.filter { $0.contains("--spaces") || $0.contains("--displays") }.count, topology,
                       "A frame-only move must not re-read Spaces or displays")
        XCTAssertFalse(fake.commands.contains { $0.contains("event=window_moved") || $0.contains("event=window_resized") || $0.contains("event=window_title_changed") })
        client.scheduleMoveRefresh()
        await client.stop()
        let stopped = fake.commands.count
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(fake.commands.count, stopped)
    }

    func testTitleFallbackSignalFollowsSettingsWithoutRemovingFocusFallbacks() async {
        let fake = FakeYabai()
        fake.signals = #"[{"label":"yabai-menu-window_title_changed","event":"window_title_changed","action":"old"}]"#
        var callbacks: [String: () -> Void] = [:]
        let client = YabaiClient(path: "/fake/yabai", notification: "test.title-fallback", run: fake.run,
            register: { name, callback in callbacks[name] = callback; return 0 },
            windowEvents: YabaiWindowEvents(trusted: { false }, supportsTitles: false), displaysAwake: { true },
            tracksWindowTitles: false, leftButtonDown: { false })
        client.start(observeSystem: false)
        await waitUntil { client.snapshot != nil }
        let titleEvent = "event=window_title_changed", label = "yabai-menu-window_title_changed"
        let titleChannel = "test.title-fallback.window-title-changed"
        XCTAssertNil(callbacks[titleChannel])
        XCTAssertTrue(fake.commands.contains(["-m", "signal", "--remove", label]))
        XCTAssertTrue(fake.commands.contains { $0.contains("event=window_focused") })
        XCTAssertFalse(fake.commands.contains { $0.contains(titleEvent) })
        client.setWindowTitleTracking(true)
        await waitUntil { fake.commands.contains { $0.contains(titleEvent) } && callbacks[titleChannel] != nil }
        try? await Task.sleep(nanoseconds: 70_000_000)
        let oldCallback = callbacks[titleChannel]
        let removals = fake.commands.filter { $0 == ["-m", "signal", "--remove", label] }.count
        let lastUpdate = client.status.lastUpdated
        client.setWindowTitleTracking(false)
        await waitUntil { fake.commands.filter { $0 == ["-m", "signal", "--remove", label] }.count > removals
            && client.status.lastUpdated != lastUpdate }
        let count = fake.commands.count
        oldCallback?()
        try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 20_000_000)
        XCTAssertEqual(fake.commands.count, count, "A late title-only signal must not start a query")
        await client.stop()
    }

    func testNativeFocusKeepsYabaiWindowFocusSignal() async {
        let fake = FakeYabai()
        fake.signals = #"[{"label":"yabai-menu-window_focused","event":"window_focused","action":"old"},{"label":"yabai-menu-space_changed","event":"space_changed","action":"old"},{"label":"yabai-menu-display_changed","event":"display_changed","action":"old"}]"#
        fake.windows = #"[{"id":10,"pid":123,"app":"Fixture","title":"","space":1,"has-focus":true,"is-floating":false,"is-sticky":false,"is-hidden":false,"is-minimized":false,"stack-index":0,"frame":{"x":0}}]"#
        let events = YabaiWindowEvents(trusted: { true }, subscribe: { _, _ in .init(cancel: {}, hasFocus: true, setTitleTracking: { $0 }) }, supportsTitles: true)
        let client = YabaiClient(path: "/fake/yabai", notification: "test.yabai-menu.\(UUID().uuidString)", run: fake.run,
                                 register: { _, _ in 0 }, windowEvents: events, displaysAwake: { true })
        client.startWindowObservation()
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        await waitUntil {
            let removed = fake.commands.filter { $0.contains("--remove") }.compactMap(\.last)
            return YabaiClient.nativeFocusEvents.allSatisfy { removed.contains("yabai-menu-\($0)") }
        }
        XCTAssertTrue(fake.commands.contains { $0.contains("event=window_created") })
        XCTAssertTrue(fake.commands.contains { $0.contains("event=window_focused") })
        XCTAssertFalse(fake.commands.contains { $0.contains("--remove") && $0.contains("yabai-menu-window_focused") })
        await client.stop()
        // Without Accessibility the yabai signals stay as the fallback.
        let plain = FakeYabai(), fallback = makeClient(plain)
        fallback.start(observeSystem: false)
        await waitUntil { fallback.status.mode == .live }
        XCTAssertTrue(plain.commands.contains { $0.contains("event=window_focused") })
        await fallback.stop()
    }

    func testStoppingDuringSignalListingCannotRegisterALateTitleListener() async {
        let fake = FakeYabai()
        fake.holdSignalList = true
        var registered = [String]()
        let client = makeClient(fake, register: { key, _ in registered.append(key); return 0 })
        client.start(observeSystem: false)
        await waitUntil { fake.releaseSignalList != nil }
        let stop = Task { await client.stop() }
        await Task.yield()
        fake.releaseSignalList?.resume()
        await stop.value
        XCTAssertFalse(registered.contains { $0.hasSuffix(".window-title-changed") })
        XCTAssertFalse(fake.commands.contains { $0.contains("--add") })
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
        let client = makeClient(fake, register: { name, callback in callbacks[name] = callback; return 0 },
                                tracksWindowTitles: false)
        client.start(observeSystem: false)
        await waitUntil { client.status.mode == .live }
        XCTAssertEqual(fake.commands.filter { $0.contains("--remove") }.map { $0.last! }, ["yabai-menu-window_moved", "yabai-menu-window_resized", "yabai-menu-window_title_changed"])
        XCTAssertEqual(fake.commands.filter { $0.contains("--displays") }.count, 1)
        XCTAssertTrue(fake.commands.contains(["-m", "query", "--displays", YabaiClient.displayFields]))
        XCTAssertTrue(fake.commands.contains(["-m", "query", "--spaces", YabaiClient.spaceFields]))
        let fieldsWithoutTitle = YabaiClient.windowFields.replacingOccurrences(of: ",title,", with: ",")
        XCTAssertTrue(fake.commands.contains(["-m", "query", "--windows", fieldsWithoutTitle]))
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
        let client = makeClient(fake, tracksWindowTitles: false)
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
