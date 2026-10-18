// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import YabaiMenuKit

@MainActor
final class DaemonMonitorTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        let end = Date(timeIntervalSinceNow: 3)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testFileReplacementAndProcessExitWithoutPolling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("daemon.socket")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["20"]
        var changes: [DaemonMonitor.Identity?] = []
        let monitor = DaemonMonitor(socketPath: socket.path, owner: { process.isRunning ? process.processIdentifier : nil }) { changes.append($0) }
        defer {
            monitor.stop()
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
        try monitor.start()
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes[0])
        try process.run()
        try Data().write(to: socket)
        await waitUntil { changes.last.flatMap { $0 }?.pid == process.processIdentifier }
        let first = changes.last.flatMap { $0 }
        try Data("replacement".utf8).write(to: socket, options: .atomic)
        await waitUntil { changes.last.flatMap { $0 }?.inode != first?.inode }
        let count = changes.count
        try Data().write(to: directory.appendingPathComponent("unrelated"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(changes.count, count, "Unrelated directory writes must not trigger daemon reconnection")
        process.terminate()
        await waitUntil { changes.count > count && changes.last.flatMap { $0 } == nil }
    }
}
