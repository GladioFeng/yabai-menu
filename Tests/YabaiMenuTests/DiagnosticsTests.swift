// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：验证诊断信息准确、无副作用且不包含私密内容。
// 代码逻辑：构造假连接状态，检查版本与事件状态，再验证错误内容不会泄漏。
// 必需输入：内存中的假 yabai 和 AX 订阅器。预期输出：诊断回归断言通过。
import AppKit
import XCTest
@testable import YabaiMenuKit

@MainActor
final class DiagnosticsTests: XCTestCase {
    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testReportIncludesBuildAndArchitectureWithoutPrivateContent() throws {
        _ = NSApplication.shared
        var settings = AppSettings(); settings.placement = .menuBar
        let controller = MenuBarController(settings: settings)
        let state = try Snapshot(spaces: Data("""
            [{"id":1,"index":1,"label":"Private Space Label","display":1,"type":"bsp","has-focus":true,"is-visible":true}]
            """.utf8), windows: Data("""
            [{"id":10,"pid":123,"app":"Private App Name","title":"Private Window Title","space":1,"has-focus":true,"is-floating":false,"is-sticky":false,"is-hidden":false,"is-minimized":false,"stack-index":0,"frame":{"x":0}}]
            """.utf8))
        controller.update(state, status: ConnectionStatus(mode: .limited, detail: "private-error-text", actionError: "private-token-value"))
        let report = controller.diagnostics(info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "23"])
        XCTAssertTrue(report.contains("Yabai Menu 1.0.0 (build 23)"))
        #if arch(arm64)
        XCTAssertTrue(report.contains("Process architecture: arm64"))
        #else
        XCTAssertTrue(report.contains("Process architecture: x86_64"))
        #endif
        XCTAssertTrue(report.contains("Spaces: 1, windows: 1"))
        XCTAssertTrue(report.contains("Accessibility: "))
        XCTAssertTrue(report.contains("Errors: connection/action error; client unavailable"))
        for value in ["Private Space Label", "Private App Name", "Private Window Title", "private-error-text", "private-token-value"] {
            XCTAssertFalse(report.contains(value))
        }
        XCTAssertTrue(controller.diagnostics(info: nil).contains("Yabai Menu development (build unknown)"))
    }

    func testSubscriptionDiagnosticsFollowLifecycleWithoutQuerying() async {
        let backend = NativeRefreshTests.Backend(), ax = YabaiWindowEventsTests.Backend()
        var trusted = true
        let native = YabaiWindowEvents(trusted: { trusted }, subscribe: ax.subscribe)
        let client = YabaiClient(path: "/fixture/yabai", notification: "test.diagnostics.\(UUID().uuidString)",
                                 run: backend.run, register: { _, _ in 0 }, windowEvents: native)
        XCTAssertTrue(client.diagnosticLines.contains("Native window subscriptions: stopped"))
        client.start(observeSystem: false)
        XCTAssertTrue(client.diagnosticLines.contains("Native window subscriptions: not started"))
        client.startWindowObservation()
        XCTAssertTrue(client.diagnosticLines.contains("Native window subscriptions: pending"))
        await waitFor { client.diagnosticLines.contains("Native window subscriptions: active") }
        let calls = backend.calls
        XCTAssertTrue(client.diagnosticLines.contains("Accessibility: granted"))
        XCTAssertTrue(client.diagnosticLines.contains("Yabai signals: ready"))
        XCTAssertTrue(client.diagnosticLines.contains("Refresh notifications: ready"))
        XCTAssertEqual(backend.calls, calls, "Reading diagnostics must not query or reconnect yabai")
        trusted = false
        XCTAssertTrue(client.diagnosticLines.contains("Accessibility: denied"))
        XCTAssertTrue(client.diagnosticLines.contains("Native window subscriptions: permission required"))
        client.screenChanged(sleeping: true)
        XCTAssertTrue(client.diagnosticLines.contains("Native window subscriptions: suspended"))
        await client.stop()
        XCTAssertTrue(client.diagnosticLines.contains("Native window subscriptions: stopped"))
        XCTAssertTrue(client.diagnosticLines.contains("Daemon monitor: stopped"))
    }

    func testSubscriptionFailureAndRecoveryAreReported() async {
        let backend = NativeRefreshTests.Backend(), ax = YabaiWindowEventsTests.Backend(failures: 1)
        let native = YabaiWindowEvents(trusted: { true }, subscribe: ax.subscribe)
        let client = YabaiClient(path: "/fixture/yabai", notification: "test.diagnostics.\(UUID().uuidString)",
                                 run: backend.run, register: { _, _ in 0 }, windowEvents: native)
        client.start(observeSystem: false)
        client.startWindowObservation()
        await waitFor { client.diagnosticLines.contains("Native window subscriptions: failed") }
        XCTAssertTrue(client.diagnosticLines.contains("Errors: native window observation unavailable"))
        await waitFor { client.diagnosticLines.contains("Native window subscriptions: active") }
        XCTAssertTrue(client.diagnosticLines.contains("Errors: none"))
        await client.stop()
    }

    func testCommandErrorsExportCategoriesInsteadOfRawText() async {
        let secret = "Private Window Title / Private Space Label / private-token-value"
        var calls = 0
        let client = YabaiClient(path: "/fixture/yabai", notification: "test.diagnostics.\(UUID().uuidString)",
            run: { _, _ in calls += 1; throw MenuError.message(secret) }, register: { _, _ in 0 }, windowEvents: nil)
        client.start(observeSystem: false)
        await waitFor { client.status.mode == .disconnected }
        client.reportActionError(secret)
        let before = calls
        let report = client.diagnosticLines.joined(separator: "\n")
        XCTAssertTrue(report.contains("state query failed"))
        XCTAssertTrue(report.contains("signal/notification setup failed"))
        XCTAssertTrue(report.contains("Space/window action failed"))
        for value in ["Private Window Title", "Private Space Label", "private-token-value"] {
            XCTAssertFalse(report.contains(value))
        }
        XCTAssertEqual(calls, before)
        await client.stop()
    }
}
