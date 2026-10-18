// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Socket replacement announces a new daemon; its advisory lock identifies the live process.
@MainActor
final class DaemonMonitor {
    struct Identity: Equatable { let inode: UInt64; let pid: pid_t }
    private let socketPath: String
    private let owner: () -> pid_t?
    private let changed: (Identity?) -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var processSource: DispatchSourceProcess?
    private var pending: DispatchWorkItem?
    private var identity: Identity?
    private var started = false

    init(socketPath: String = "/tmp/yabai_\(NSUserName()).socket",
         owner: (() -> pid_t?)? = nil, changed: @escaping (Identity?) -> Void) {
        self.socketPath = socketPath
        self.owner = owner ?? { Self.lockOwner("/tmp/yabai_\(NSUserName()).lock") }
        self.changed = changed
    }

    func start() throws {
        guard !started else { return }
        let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        let fd = open(parent, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { throw MenuError.message("Cannot observe yabai socket: \(String(cString: strerror(errno)))") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleCheck() }
        }
        source.setCancelHandler { close(fd) }
        directorySource = source
        started = true
        source.resume()
        check(force: true)
    }

    private func scheduleCheck() {
        guard started, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.check()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func check(force: Bool = false) {
        guard started else { return }
        var info = stat()
        let next: Identity?
        if stat(socketPath, &info) == 0, let pid = owner(), pid > 0 {
            next = Identity(inode: UInt64(info.st_ino), pid: pid)
        } else { next = nil }
        guard force || next != identity else { return }
        identity = next
        processSource?.cancel()
        processSource = nil
        if let next {
            let source = DispatchSource.makeProcessSource(identifier: next.pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, self.started, self.identity == next else { return }
                    self.identity = nil
                    self.processSource?.cancel()
                    self.processSource = nil
                    self.changed(nil)
                }
            }
            processSource = source
            source.resume()
        }
        changed(next)
    }

    func stop() {
        started = false
        pending?.cancel()
        directorySource?.cancel()
        processSource?.cancel()
        directorySource = nil
        processSource = nil
    }

    private static func lockOwner(_ path: String) -> pid_t? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_GETLK, &lock) != -1, lock.l_type != F_UNLCK else { return nil }
        return lock.l_pid
    }

    deinit {
        directorySource?.cancel()
        processSource?.cancel()
        pending?.cancel()
    }
}
