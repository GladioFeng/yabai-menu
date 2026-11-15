// SPDX-License-Identifier: GPL-3.0-only
// Scenarios adapted from a-barTests/YabaiServiceTests.swift.
import ApplicationServices
import AppKit
import XCTest
@testable import YabaiMenuKit

@MainActor
final class NativeRefreshTests: XCTestCase {
    @MainActor final class Backend {
        var calls: [[String]] = []
        var foreground: pid_t = 123
        var focusedDisplay = 1
        var single: [String: Any]?
        var failQueries = false
        var holdNextFocus = false
        var releaseFocus: CheckedContinuation<Void, Never>?
        var holdNextWindows = false
        var releaseWindows: CheckedContinuation<Void, Never>?
        var windows: [[String: Any]] = [10, 11].map { id in
            ["id": id, "pid": 123, "app": "Fixture", "title": "A", "space": 1, "display": 1,
             "subrole": "AXStandardWindow", "has-focus": id == 10, "is-visible": true,
             "is-floating": false, "is-sticky": false, "is-hidden": false, "is-minimized": false,
             "stack-index": 0, "frame": ["x": Double(id)]]
        }
        var queryCalls: [[String]] { calls.filter { $0.contains("query") } }
        func run(_ path: String, _ args: [String]) async throws -> Data {
            calls.append(args)
            if args.contains("signal") { return Data("[]".utf8) }
            if failQueries { throw MenuError.message("Fixture query failure") }
            let object: Any
            if args.contains("--windows") {
                if let position = args.firstIndex(of: "--window") {
                    let id = args.indices.contains(position + 1) ? Int(args[position + 1]) : nil
                    guard let window = single ?? windows.first(where: { id == nil ? $0["has-focus"] as? Bool == true : $0["id"] as? Int == id }) else {
                        throw MenuError.message("could not retrieve window details.")
                    }
                    object = window
                } else { object = windows }
            } else if args.contains("--spaces") {
                object = (1...2).map { index -> [String: Any] in
                    ["id": index, "index": index, "label": "Work", "display": index, "type": "bsp",
                     "windows": windows.filter { $0["space"] as? Int == index }.compactMap { $0["id"] as? Int },
                     "has-focus": focusedDisplay == index, "is-visible": true]
                }
            } else {
                object = (1...2).map { ["id": $0 + 100, "index": $0, "uuid": "test-\($0)", "has-focus": focusedDisplay == $0] }
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            if args.contains("--window"), holdNextFocus {
                holdNextFocus = false
                await withCheckedContinuation { releaseFocus = $0 }
            }
            if args.contains("--windows"), !args.contains("--window"), holdNextWindows {
                holdNextWindows = false
                await withCheckedContinuation { releaseWindows = $0 }
            }
            return data
        }
    }

    private func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func client(_ backend: Backend, events: YabaiWindowEvents? = nil,
                        delayAutomaticFocus: Bool = true,
                        leftButtonDown: @escaping () -> Bool = { false }) -> YabaiClient {
        YabaiClient(path: "/fixture/yabai", notification: "test.native.\(UUID().uuidString)", run: backend.run,
                    register: { _, _ in 0 }, windowEvents: events, frontmostPID: { backend.foreground },
                    delayAutomaticFocus: delayAutomaticFocus, leftButtonDown: leftButtonDown)
    }

    private func start(_ client: YabaiClient) async {
        client.start(observeSystem: false)
        await waitFor { client.status.mode == .live }
    }

    private func observe(_ native: YabaiWindowEvents, client: YabaiClient, backend: YabaiWindowEventsTests.Backend) async throws {
        native.start { [weak client] event in
            switch event {
            case .moved: client?.scheduleMoveRefresh()
            case .titleChanged(let id, let pid, let element, let title): client?.applyNativeTitle(id: id, pid: pid, element: element, title: title)
            default: break
            }
        }
        native.update(try XCTUnwrap(client.snapshot).windows)
        await waitFor { backend.registered == [123] }
    }

    func testFocusNotificationPatchesLocallyAndClearsPreviousFocus() async {
        let backend = Backend()
        var handlers: [String: () -> Void] = [:]
        let client = YabaiClient(path: "/fixture/yabai", notification: "test.native.\(UUID().uuidString)", run: backend.run,
            register: { name, handler in handlers[name] = handler; return 0 }, windowEvents: nil,
            frontmostPID: { 123 }, readFocus: { _ in 11 }, leftButtonDown: { false })
        await start(client)
        backend.calls.removeAll()
        backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
        handlers.first { $0.key.hasSuffix(".window-focused") }?.value()
        await waitFor { client.snapshot?.focusedWindow?.id == 11 }
        XCTAssertTrue(backend.queryCalls.isEmpty, "yabai's window ID is enough for a known window")
        XCTAssertEqual(client.snapshot?.windows.filter(\.focused).count, 1)
        await client.stop()
    }


    func testOverlappingFocusQueriesReuseMatchingQuery() async {
        let backend = Backend(); let client = client(backend)
        await start(client)
        backend.calls.removeAll()
        backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
        backend.holdNextFocus = true
        client.refresh(.focus(nil))
        await waitFor { backend.releaseFocus != nil }
        client.refresh(.focus(11))
        backend.releaseFocus?.resume(); backend.releaseFocus = nil
        await waitFor { client.snapshot?.focusedWindow?.id == 11 }
        XCTAssertEqual(backend.queryCalls.count, 1, "One click must not query the same focused window twice")
        XCTAssertEqual(client.snapshot?.windows.filter(\.focused).count, 1)
        await client.stop()
    }

    func testOverlappingFocusPreservesNewerTargetsAndBroaderRefreshes() async {
        for latest: YabaiClient.RefreshScope in [.focus(10), .focus(nil), .windows, .full] {
            let backend = Backend(); let client = client(backend)
            await start(client); backend.calls.removeAll()
            backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
            backend.holdNextFocus = true
            let before = client.status.lastUpdated
            client.refresh(.focus(nil))
            await waitFor { backend.releaseFocus != nil }
            // The suspended response still describes window 11; the latest state is window 10.
            backend.windows[0]["has-focus"] = true; backend.windows[1]["has-focus"] = false
            client.refresh(latest)
            backend.releaseFocus?.resume(); backend.releaseFocus = nil
            await waitFor { client.status.lastUpdated != before }
            XCTAssertEqual(client.snapshot?.focusedWindow?.id, 10, "\(latest)")
            XCTAssertEqual(backend.queryCalls.count, latest == .full ? 4 : 2, "\(latest)")
            if latest == .windows || latest == .full {
                XCTAssertTrue(backend.queryCalls.contains { $0.contains("--windows") && !$0.contains("--window") })
            }
            await client.stop()
        }
    }

    func testOverlappingFocusDuringTitleReadKeepsLatestRequest() async throws {
        for latestID in [11, 10] {
            let backend = Backend(), ax = YabaiWindowEventsTests.Backend()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            var firstRead = true
            let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe, titleReader: { _ in
                if firstRead {
                    firstRead = false
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return "Native B"
            })
            let client = client(backend, events: native)
            await start(client); try await observe(native, client: client, backend: ax)
            ax.emit(.titleChanged(id: 11, pid: 123, element: AXUIElementCreateApplication(123), title: "Native B"))
            await waitFor { client.snapshot?.windows.first { $0.id == 11 }?.title == "Native B" }
            backend.calls.removeAll()
            backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
            let before = client.status.lastUpdated
            client.refresh(.focus(nil))
            var reading = false
            await waitFor {
                if !reading { reading = entered.wait(timeout: .now()) == .success }
                return reading
            }
            backend.windows[0]["has-focus"] = latestID == 10
            backend.windows[1]["has-focus"] = latestID == 11
            var published: [Int?] = []
            client.onUpdate = { state, _ in published.append(state?.focusedWindow?.id) }
            client.refresh(.focus(latestID))
            release.signal()
            await waitFor { client.status.lastUpdated != before }
            XCTAssertEqual(client.snapshot?.focusedWindow?.id, latestID)
            XCTAssertEqual(backend.queryCalls.count, latestID == 11 ? 1 : 2)
            XCTAssertFalse(published.contains { $0 != latestID }, "A newer focus must not publish the old target")
            await client.stop()
        }
    }

    func testAutomaticFocusWaitsAndCoalescesClickNotifications() async {
        let backend = Backend()
        var handlers: [String: () -> Void] = [:]
        var focusID = 10
        let client = YabaiClient(path: "/fixture/yabai", notification: "test.delay",
            run: backend.run, register: { name, handler in handlers[name] = handler; return 0 },
            windowEvents: nil, frontmostPID: { backend.foreground }, readFocus: { _ in focusID }, leftButtonDown: { false })
        await start(client); backend.calls.removeAll()
        backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
        client.handleAppNotification(Notification(name: NSWorkspace.didActivateApplicationNotification))
        handlers.first { $0.key.hasSuffix(".window-focused") }?.value()
        focusID = 11
        handlers.first { $0.key.hasSuffix(".window-focused") }?.value()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(backend.queryCalls.isEmpty, "Automatic refresh must leave the first drag frames alone")
        await waitFor { client.snapshot?.focusedWindow?.id == 11 }
        XCTAssertTrue(backend.queryCalls.isEmpty, "The latest click target is applied locally")
        await client.stop()
    }

    func testFocusAcrossDisplaysPatchesLocallyWithoutYabaiQueries() async {
        let backend = Backend()
        backend.windows[1]["space"] = 2; backend.windows[1]["display"] = 2
        let client = client(backend)
        await start(client); backend.calls.removeAll()
        XCTAssertEqual(client.snapshot?.focusedWindow?.id, 10)
        client.scheduleFocusRefresh(11, native: true) // AX focus event for a window on the other display
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotEqual(client.snapshot?.focusedWindow?.id, 11, "Nothing runs until interaction is quiet")
        await waitFor { client.snapshot?.focusedWindow?.id == 11 }
        XCTAssertEqual(client.snapshot?.focusedSpace?.index, 2)
        XCTAssertEqual(client.snapshot?.displays.filter { $0.focused == true }.map(\.index), [2])
        XCTAssertEqual(client.snapshot?.windows.filter(\.focused).map(\.id), [11])
        XCTAssertTrue(backend.queryCalls.isEmpty, "A known on-screen window needs no yabai query")
        // A window the snapshot does not know falls back to yabai once.
        backend.windows.append(["id": 12, "pid": 123, "app": "Fixture", "title": "C", "space": 1, "display": 1,
                                "subrole": "AXStandardWindow", "has-focus": true, "is-visible": true, "is-floating": false,
                                "is-sticky": false, "is-hidden": false, "is-minimized": false, "stack-index": 0, "frame": ["x": 12.0]])
        for i in backend.windows.indices where backend.windows[i]["id"] as? Int != 12 { backend.windows[i]["has-focus"] = false }
        // From AX, an unmanaged panel/popover ID is ignored: no yabai query, focus unchanged.
        client.scheduleFocusRefresh(12, native: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(backend.queryCalls.isEmpty, "Unmanaged AX focus must not cost yabai a query")
        XCTAssertEqual(client.snapshot?.focusedWindow?.id, 11)
        // From yabai's own focus signal (fallback mode), an unknown window is resolved through yabai.
        client.scheduleFocusRefresh(12)
        await waitFor { client.snapshot?.focusedWindow?.id == 12 }
        XCTAssertFalse(backend.queryCalls.isEmpty)
        await client.stop()
    }

    func testDragMovesPostponeAllDeferredWorkUntilQuiet() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll()
        var published = 0
        client.onUpdate = { _, _ in published += 1 }
        client.scheduleFocusRefresh(11) // click
        client.scheduleRefresh()         // e.g. a Space notification at the same moment
        for _ in 0..<8 {                 // drag: move events keep arriving
            client.scheduleMoveRefresh()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(backend.queryCalls.isEmpty, "No query while the drag is still producing events")
        XCTAssertEqual(published, 0, "No redraw while the drag is still producing events")
        await waitFor { !backend.queryCalls.isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.queryCalls.filter { $0.contains("--spaces") }.count, 1, "One merged full refresh after the drag")
        await client.stop()
        let stopped = backend.calls.count
        client.scheduleMoveRefresh()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(backend.calls.count, stopped, "Nothing runs after stop")
    }

    func testEndlessMoveEventsCannotPostponeRefreshPastTheCap() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll()
        let begin = Date()
        var firstQuery: TimeInterval?
        for _ in 0..<40 { // ~4 s of a window that never stops moving
            client.scheduleMoveRefresh()
            try? await Task.sleep(nanoseconds: 100_000_000)
            if firstQuery == nil, !backend.queryCalls.isEmpty { firstQuery = Date().timeIntervalSince(begin) }
        }
        let at = try? XCTUnwrap(firstQuery, "Refresh must run while events continue")
        XCTAssertGreaterThanOrEqual(at ?? 0, 2.9)
        XCTAssertLessThan(at ?? 99, 3.6)
        await client.stop()
    }

    func testHeldLeftButtonOutlastsCapAndMergesFocusWithWindowsOnRelease() async {
        let backend = Backend()
        var down = false
        let client = client(backend, leftButtonDown: { down })
        await start(client); backend.calls.removeAll()
        var published = 0
        client.onUpdate = { _, _ in published += 1 }
        down = true
        backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
        backend.windows[1]["frame"] = ["x": 500.0]
        client.scheduleFocusRefresh(11, native: true)
        client.scheduleMoveRefresh()
        // 按住但不继续移动，超过旧的三秒上限仍不得开始查询或绘制。
        try? await Task.sleep(nanoseconds: YabaiClient.maxDeferral + YabaiClient.quietPeriod + 50_000_000)
        XCTAssertTrue(backend.queryCalls.isEmpty)
        XCTAssertEqual(published, 0)
        down = false
        client.resumeDeferredAfterMouseUp()
        await waitFor { published > 0 && client.snapshot?.focusedWindow?.id == 11 }
        try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 50_000_000)
        XCTAssertEqual(client.snapshot?.focusedWindow?.frame.x, 500)
        XCTAssertEqual(published, 1, "Focus and moved geometry must become visible together")
        XCTAssertEqual(backend.queryCalls.count, 3, "One full batch covers the pending focus and windows")
        for domain in ["--windows", "--spaces", "--displays"] {
            XCTAssertEqual(backend.queryCalls.filter { $0.contains(domain) }.count, 1)
        }
        await client.stop()
    }

    func testHeldTitlesKeepLatestAndRecoverWithoutMouseUpNotification() async {
        let backend = Backend()
        var down = false
        let client = client(backend, leftButtonDown: { down })
        await start(client); backend.calls.removeAll()
        var published: [String] = []
        client.onUpdate = { state, _ in
            published.append(state?.windows.first { $0.id == 11 }?.title ?? "missing")
        }
        down = true
        let element = AXUIElementCreateApplication(123)
        client.applyNativeTitle(id: 11, pid: 123, element: element, title: "Native B")
        client.applyNativeTitle(id: 11, pid: 123, element: element, title: "Native C")
        client.applyNativeTitle(id: 11, pid: 456, element: element, title: "Wrong owner")
        try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 50_000_000)
        XCTAssertTrue(published.isEmpty)
        XCTAssertTrue(backend.queryCalls.isEmpty)
        // 不调用 mouseUp 回调：只在有待交付状态时运行的补救检查仍须发现松手。
        down = false
        await waitFor { !published.isEmpty }
        try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 50_000_000)
        XCTAssertEqual(published, ["Native C"])
        XCTAssertTrue(backend.queryCalls.isEmpty, "Valid native titles do not need a yabai query")
        await client.stop()
    }

    func testAutomaticQueryFinishingWhileHeldWaitsForFreshStateAfterRelease() async throws {
        let backend = Backend()
        var down = false
        let client = client(backend, leftButtonDown: { down })
        await start(client); backend.calls.removeAll()
        var published: [Double] = []
        client.onUpdate = { state, _ in
            published.append(state?.windows.first { $0.id == 10 }?.frame.x ?? -1)
        }
        backend.windows[0]["frame"] = ["x": 500.0]
        backend.holdNextWindows = true
        client.scheduleMoveRefresh()
        await waitFor { backend.releaseWindows != nil }
        let response = try XCTUnwrap(backend.releaseWindows)
        backend.releaseWindows = nil
        down = true
        // 已冻结的响应仍是 500；松手后必须获取并发布 600，不能泄漏旧响应。
        backend.windows[0]["frame"] = ["x": 600.0]
        response.resume()
        try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 50_000_000)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(backend.queryCalls.count, 1)
        down = false
        client.resumeDeferredAfterMouseUp()
        await waitFor { published == [600] }
        try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 50_000_000)
        XCTAssertEqual(published, [600])
        XCTAssertEqual(backend.queryCalls.count, 2)
        XCTAssertTrue(backend.queryCalls.allSatisfy { $0.contains("--windows") && !$0.contains("--window") })
        await client.stop()
    }

    func testBothFocusDelaySettingsRespectHeldButtonAndPendingSettingChanges() async {
        for delay in [false, true] {
            let backend = Backend()
            var down = false
            let client = client(backend, delayAutomaticFocus: delay, leftButtonDown: { down })
            await start(client); backend.calls.removeAll()
            var published = 0
            client.onUpdate = { _, _ in published += 1 }
            client.scheduleFocusRefresh(11, native: true)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(published, delay ? 0 : 1, "Only the 300 ms setting waits for a quiet focus")
            await waitFor { client.snapshot?.focusedWindow?.id == 11 }
            down = true
            client.scheduleFocusRefresh(10, native: true)
            client.delayAutomaticFocus = !delay
            try? await Task.sleep(nanoseconds: YabaiClient.quietPeriod + 50_000_000)
            XCTAssertEqual(published, 1, "Changing the delay must not bypass the held-button gate")
            XCTAssertEqual(client.snapshot?.focusedWindow?.id, 11)
            down = false
            client.resumeDeferredAfterMouseUp()
            await waitFor { client.snapshot?.focusedWindow?.id == 10 }
            XCTAssertEqual(published, 2)
            XCTAssertTrue(backend.queryCalls.isEmpty)
            await client.stop()
        }
    }

    func testZeroFocusDelayKeepsWindowAndFullRefreshQuietPeriod() async {
        for full in [false, true] {
            let backend = Backend(); let client = client(backend, delayAutomaticFocus: false)
            await start(client); backend.calls.removeAll()
            let before = client.status.lastUpdated
            if full { client.scheduleRefresh() } else { client.scheduleMoveRefresh() }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(backend.queryCalls.isEmpty, "The zero setting applies only to pure focus")
            await waitFor { client.status.lastUpdated != before }
            XCTAssertEqual(backend.queryCalls.count, full ? 3 : 1)
            await client.stop()
        }
    }

    func testActivationIsNotLostWhenItsAXWindowIsUnmanaged() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll()
        // Switching apps: activation (no ID) plus an AX focus event for a panel yabai does not list.
        client.handleAppNotification(Notification(name: NSWorkspace.didActivateApplicationNotification,
                                                  userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]))
        client.scheduleFocusRefresh(999, native: true)
        await waitFor { !backend.queryCalls.isEmpty }
        XCTAssertEqual(backend.queryCalls.first, ["-m", "query", "--windows", YabaiClient.windowFields, "--window"],
                       "The activation still resolves the app's focused window")
        await client.stop()
    }

    func testDeferredFocusDiscardsOlderQueuedFocus() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll()
        backend.holdNextFocus = true
        client.refresh(.focus(10))
        await waitFor { backend.releaseFocus != nil }
        client.refresh(.focus(10))
        backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
        var published: [Int?] = []
        client.onUpdate = { snapshot, _ in published.append(snapshot?.focusedWindow?.id) }
        client.scheduleFocusRefresh(11)
        backend.releaseFocus?.resume(); backend.releaseFocus = nil
        await waitFor { client.snapshot?.focusedWindow?.id == 11 }
        XCTAssertFalse(published.contains { $0 != 11 })
        XCTAssertEqual(backend.queryCalls.count, 1, "The stale in-flight query is discarded; the newer focus is local")
        await client.stop()
    }

    func testDeferredFocusCancelsOnStopSleepAndFullRefresh() async {
        for action in ["stop", "sleep", "full"] {
            let backend = Backend(); let client = client(backend)
            await start(client); backend.calls.removeAll()
            client.scheduleFocusRefresh(11)
            switch action {
            case "stop": await client.stop()
            case "sleep": client.screenChanged(sleeping: true)
            default:
                let before = client.status.lastUpdated
                client.refresh()
                await waitFor { client.status.lastUpdated != before }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(backend.queryCalls.contains { $0.contains("--window") }, action)
            XCTAssertEqual(backend.queryCalls.count, action == "full" ? 3 : 0, action)
            await client.stop()
        }
    }

    func testUncertainFocusFallsBackExactlyOnce() async {
        for (field, value) in [("id", 99 as Any), ("pid", 456), ("space", 2), ("display", 2),
                               ("is-hidden", true), ("is-minimized", true), ("is-visible", false), ("has-focus", false)] {
            let backend = Backend(); let client = client(backend)
            await start(client); backend.calls.removeAll()
            var window = backend.windows[1]; window["has-focus"] = true; window[field] = value; backend.single = window
            let before = client.status.lastUpdated
            client.refresh(.focus(11))
            await waitFor { client.status.lastUpdated != before }
            XCTAssertEqual(backend.queryCalls.filter { $0.contains("--windows") }.count, 2, field)
            XCTAssertEqual(backend.queryCalls.filter { $0.contains("--spaces") }.count, 1, field)
            XCTAssertEqual(client.snapshot?.focusedWindow?.id, 10, field)
            await client.stop()
        }
    }

    func testDesktopAppDesktopDoesNotPublishTemporaryDisconnection() async {
        let backend = Backend(); let client = client(backend)
        var finder = backend.windows[0]
        finder["id"] = 20; finder["pid"] = 456; finder["app"] = "Finder"; finder["has-focus"] = false
        backend.windows.append(finder)
        await start(client)
        var modes: [ConnectionStatus.Mode] = []
        client.onUpdate = { _, status in modes.append(status.mode) }
        let steps: [(pid_t, Int?)] = [(456, nil), (123, 10), (456, nil)]
        for (foreground, focusedWindow) in steps {
            backend.foreground = foreground
            for index in backend.windows.indices {
                backend.windows[index]["has-focus"] = (backend.windows[index]["id"] as? Int) == focusedWindow
            }
            backend.calls.removeAll()
            let before = client.status.lastUpdated
            client.handleAppNotification(Notification(name: NSWorkspace.didActivateApplicationNotification))
            await waitFor { client.status.lastUpdated != before }
            XCTAssertEqual(client.snapshot?.focusedWindow?.id, focusedWindow)
            XCTAssertEqual(client.snapshot?.focusedSpace?.id, 1)
            XCTAssertEqual(backend.queryCalls.filter { $0.contains("--windows") }.count, focusedWindow == nil ? 2 : 1)
            XCTAssertEqual(backend.queryCalls.filter { $0.contains("--spaces") }.count, focusedWindow == nil ? 1 : 0)
        }
        XCTAssertFalse(modes.isEmpty)
        XCTAssertTrue(modes.allSatisfy { $0 == .live }, "A missing focused window on the desktop must not disable and re-enable the bar")
        await client.stop()
    }

    func testFailedNativeSubscriptionRecoversWithoutAnotherExternalEvent() async {
        let backend = Backend(), ax = YabaiWindowEventsTests.Backend(failures: 1)
        let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe)
        let client = client(backend, events: native)
        client.start(observeSystem: false)
        client.startWindowObservation()
        await waitFor { client.status.mode == .limited }
        await waitFor { ax.registered.count == 2 && client.status.mode == .live }
        XCTAssertEqual(ax.registered, [123, 123])
        await client.stop()
    }

    func testNativeSubscriptionRecoveryIsBoundedAndClearsWhenAppExits() async {
        let backend = Backend(), ax = YabaiWindowEventsTests.Backend(failures: .max)
        let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe)
        let client = client(backend, events: native)
        client.start(observeSystem: false)
        client.startWindowObservation()
        await waitFor { client.status.mode == .limited }
        await waitFor({ ax.registered.count >= 4 }, timeout: 8)
        XCTAssertEqual(ax.registered.count, 4, "Initial attempt plus three retries")
        client.refresh()
        await waitFor { ax.registered.count >= 5 }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(ax.registered.count, 5, "A successful query must not reset the failed subscription's retry budget")
        XCTAssertEqual(client.status.mode, .limited)
        backend.windows = []
        client.refresh()
        await waitFor { client.status.mode == .live }
        await client.stop()
    }

    func testNativeSubscriptionRetryStopsDuringSleepAndShutdown() async {
        for shutdown in [false, true] {
            let backend = Backend(), ax = YabaiWindowEventsTests.Backend(failures: 1)
            let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe)
            let client = client(backend, events: native)
            client.start(observeSystem: false)
            client.startWindowObservation()
            await waitFor { client.status.mode == .limited }
            if shutdown { await client.stop() }
            else { client.screenChanged(sleeping: true) }
            let count = backend.queryCalls.count
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            XCTAssertEqual(ax.registered.count, 1)
            XCTAssertEqual(backend.queryCalls.count, count)
            if !shutdown {
                client.screenChanged(sleeping: false)
                await waitFor { ax.registered.count == 2 && client.status.mode == .live }
                await client.stop()
            }
        }
    }

    func testFocusStaysTargetedAfterSwitchingDisplays() async {
        let backend = Backend(); let client = client(backend)
        await start(client)
        backend.focusedDisplay = 2
        backend.windows[0]["has-focus"] = false
        backend.windows[1]["display"] = 2; backend.windows[1]["space"] = 2; backend.windows[1]["has-focus"] = true
        var third = backend.windows[1]; third["id"] = 12; third["has-focus"] = false
        backend.windows.append(third)
        client.refresh()
        await waitFor { client.snapshot?.focusedSpace?.display == 2 }
        XCTAssertEqual(client.snapshot?.displays.first(where: { $0.focused == true })?.index, 2)
        backend.calls.removeAll()
        backend.windows[1]["has-focus"] = false; backend.windows[2]["has-focus"] = true
        client.refresh(.focus(12))
        await waitFor { client.snapshot?.focusedWindow?.id == 12 }
        XCTAssertEqual(backend.queryCalls, [["-m", "query", "--windows", YabaiClient.windowFields, "--window", "12"]])
        await client.stop()
    }

    func testNativeTitleUsesNoQueryAndStaleBackendCannotOverwriteIt() async throws {
        let backend = Backend()
        let ax = YabaiWindowEventsTests.Backend(title: "Native B")
        let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe, titleReader: { _ in ax.title })
        let client = client(backend, events: native)
        await start(client); try await observe(native, client: client, backend: ax)
        backend.calls.removeAll()
        let element = AXUIElementCreateApplication(123)
        ax.emit(.titleChanged(id: 11, pid: 123, element: element, title: "Native B"))
        await waitFor { client.snapshot?.windows[1].title == "Native B" }
        XCTAssertEqual(client.snapshot?.windows[0].title, "A")
        XCTAssertTrue(backend.queryCalls.isEmpty, "Native title updates must not spawn yabai")
        let before = client.status.lastUpdated; client.refresh()
        await waitFor { client.status.lastUpdated != before }
        XCTAssertEqual(client.snapshot?.windows[1].title, "Native B")
        ax.title = nil; backend.windows[1]["title"] = "Backend C"
        client.refresh()
        await waitFor { client.snapshot?.windows[1].title == "Backend C" }
        backend.windows[1]["pid"] = 456; backend.windows[1]["title"] = "Reused ID"
        ax.emit(.titleChanged(id: 11, pid: 123, element: element, title: "Old process"))
        client.refresh()
        await waitFor { client.snapshot?.windows[1].pid == 456 }
        XCTAssertEqual(client.snapshot?.windows[1].title, "Reused ID")
        await client.stop()
    }

    func testLateTitleConfirmationCannotOverwriteNewNativeTitle() async throws {
        let backend = Backend(), ax = YabaiWindowEventsTests.Backend()
        let element = AXUIElementCreateApplication(123)
        var sentNewer = false
        let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe, titleReader: { _ in
            if !sentNewer {
                sentNewer = true
                ax.emitInline(.titleChanged(id: 10, pid: 123, element: element, title: "Native C"))
                DispatchQueue.main.sync {}
                return "Native B"
            }
            return "Native C"
        })
        let client = client(backend, events: native)
        await start(client); try await observe(native, client: client, backend: ax)
        ax.emit(.titleChanged(id: 10, pid: 123, element: element, title: "Native B"))
        await waitFor { client.snapshot?.focusedWindow?.title == "Native B" }
        let before = client.status.lastUpdated; client.refresh()
        await waitFor { client.status.lastUpdated != before }
        XCTAssertEqual(client.snapshot?.focusedWindow?.title, "Native C")
        await client.stop()
    }

    func testChangedWindowMembershipRequiresFullSnapshot() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll()
        var new = backend.windows[1]; new["id"] = 12; backend.windows.append(new)
        client.refresh(.windows)
        await waitFor { client.snapshot?.windows.count == 3 }
        XCTAssertEqual(backend.queryCalls.filter { $0.contains("--windows") }.count, 2)
        XCTAssertEqual(backend.queryCalls.filter { $0.contains("--spaces") }.count, 1)
        await client.stop()
    }

    func testMoveRefreshReadsWindowsOnlyUnlessSpaceChanges() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll()
        backend.windows[0]["frame"] = ["x": 500.0]
        client.scheduleMoveRefresh()
        await waitFor { client.snapshot?.windows.first { $0.id == 10 }?.frame.x == 500 }
        XCTAssertEqual(backend.queryCalls, [["-m", "query", "--windows", YabaiClient.windowFields]])
        // Dragging to another Space changes topology: the windows path must escalate to a full snapshot.
        backend.calls.removeAll()
        backend.windows[0]["space"] = 2; backend.windows[0]["display"] = 2
        client.scheduleMoveRefresh()
        await waitFor { client.snapshot?.windows.first { $0.id == 10 }?.space == 2 }
        XCTAssertEqual(backend.queryCalls.filter { $0.contains("--spaces") }.count, 1)
        XCTAssertEqual(client.snapshot?.spaces.first { $0.index == 2 }?.windows?.contains(10), true)
        await client.stop()
    }

    func testStoppedTitleReadCannotPublishOrQueueFull() async throws {
        let backend = Backend(), ax = YabaiWindowEventsTests.Backend()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe, titleReader: { _ in
            entered.signal(); _ = release.wait(timeout: .now() + 2); return "late"
        })
        let client = client(backend, events: native)
        await start(client); try await observe(native, client: client, backend: ax)
        ax.emit(.titleChanged(id: 10, pid: 123, element: AXUIElementCreateApplication(123), title: "Native B"))
        await waitFor { client.snapshot?.focusedWindow?.title == "Native B" }
        client.refresh()
        var reading = false
        await waitFor {
            if !reading { reading = entered.wait(timeout: .now()) == .success }
            return reading
        }
        var publications = 0; client.onUpdate = { _, _ in publications += 1 }
        let stop = Task { await client.stop() }
        await Task.yield(); release.signal(); await stop.value
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(client.snapshot?.focusedWindow?.title, "Native B")
        let count = backend.calls.count
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(backend.calls.count, count)
    }

    func testPartialFailureFallsBackOnceThenUsesBoundedRecovery() async {
        let backend = Backend(); let client = client(backend)
        await start(client); backend.calls.removeAll(); backend.failQueries = true
        client.refresh(.focus(10))
        await waitFor { backend.queryCalls.filter { $0.contains("--windows") }.count == 2 }
        await waitFor { client.status.mode == .disconnected }
        XCTAssertEqual(backend.queryCalls.filter { $0.contains("--spaces") }.count, 1)
        await client.stop()
    }
}
