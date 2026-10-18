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
            return try JSONSerialization.data(withJSONObject: object)
        }
    }

    private func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func client(_ backend: Backend, events: YabaiWindowEvents? = nil) -> YabaiClient {
        YabaiClient(path: "/fixture/yabai", notification: "test.native.\(UUID().uuidString)", run: backend.run,
                    register: { _, _ in 0 }, windowEvents: events, frontmostPID: { backend.foreground })
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

    func testFocusNotificationQueriesOneWindowAndClearsPreviousFocus() async {
        let backend = Backend()
        var handlers: [String: () -> Void] = [:]
        let client = YabaiClient(path: "/fixture/yabai", notification: "test.native.\(UUID().uuidString)", run: backend.run,
            register: { name, handler in handlers[name] = handler; return 0 }, windowEvents: nil,
            frontmostPID: { 123 }, readFocus: { _ in 11 })
        await start(client)
        backend.calls.removeAll()
        backend.windows[0]["has-focus"] = false; backend.windows[1]["has-focus"] = true
        handlers.first { $0.key.hasSuffix(".window-focused") }?.value()
        await waitFor { client.snapshot?.focusedWindow?.id == 11 }
        XCTAssertEqual(backend.queryCalls, [["-m", "query", "--windows", YabaiClient.windowFields, "--window", "11"]])
        XCTAssertEqual(client.snapshot?.windows.filter(\.focused).count, 1)
        await client.stop()
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
