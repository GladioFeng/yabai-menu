// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

enum Command {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 3) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = errors
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                // Drain both pipes while yabai runs, including output larger than the pipe buffer.
                let deadline = DispatchTime.now() + timeout
                let out = Drain(output, deadline: deadline), err = Drain(errors, deadline: deadline)
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: deadline)
                timer.setEventHandler {
                    if process.isRunning {
                        process.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
                timer.resume()
                process.waitUntilExit()
                timer.cancel()
                let data = out.result(), diagnostic = err.result()
                let complete = DispatchTime.now() < deadline && !out.overflow && !err.overflow && !out.failed && !err.failed
                guard complete, process.terminationStatus == 0 else {
                    // yabai reports a successful no-op as an error when the display already has focus.
                    if complete, process.terminationStatus == 1, arguments.count == 4,
                       arguments.starts(with: ["-m", "display", "--focus"]),
                       String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "cannot focus an already focused display." {
                        continuation.resume(returning: data)
                        return
                    }
                    if complete, process.terminationStatus == 1, arguments.count == 4,
                       arguments.starts(with: ["-m", "space", "--focus"]),
                       String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "cannot focus an already focused space." {
                        continuation.resume(throwing: MenuError.alreadyFocusedSpace)
                        return
                    }
                    let detail = String(decoding: diagnostic.prefix(300), as: UTF8.self)
                    let reason = DispatchTime.now() >= deadline ? "Command timed out." : "Command failed (\(process.terminationStatus)) or returned too much output."
                    continuation.resume(throwing: MenuError.message("\(reason) \(detail)"))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private final class Drain {
        private let group = DispatchGroup()
        private var data = Data()
        private(set) var overflow = false
        private(set) var failed = false
        init(_ pipe: Pipe, deadline: DispatchTime) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                defer { try? handle.close(); self.group.leave() }
                let fd = handle.fileDescriptor
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { self.failed = true; return }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while DispatchTime.now() < deadline {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 50)
                    if ready == 0 { continue }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        self.failed = true; return
                    }
                    let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if count == 0 { return }
                    if count < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        self.failed = true; return
                    }
                    let available = max(0, 8 * 1024 * 1024 - self.data.count)
                    self.data.append(contentsOf: buffer.prefix(min(count, available)))
                    if count > available { self.overflow = true }
                }
                self.failed = true
            }
        }
        func result() -> Data { group.wait(); return data }
    }
}
