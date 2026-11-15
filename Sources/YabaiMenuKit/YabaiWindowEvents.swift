// SPDX-License-Identifier: GPL-3.0-only
// 代码目的：复用 a-bar 的原生窗口移动和标题事件链。
// 代码逻辑：1. 每应用一个 AX 订阅；2. 后台读取和去重；3. 按 generation 安全停止。
// 必需输入：窗口成员和事件回调。预期输出：移动、标题变化、重同步或权限丢失事件。
// Adapted from a-bar/Services/YabaiWindowEvents.swift.
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

/// Application-level AX subscriptions cover existing and newly created windows without
/// spawning a process for each move/title notification. All AX I/O stays off the UI thread.
final class YabaiWindowEvents {
    enum Event {
        case moved
        case focused(id: Int, pid: pid_t)
        case titleChanged(id: Int, pid: pid_t, element: AXUIElement, title: String?)
        case resynchronized
        case permissionLost
        case subscriptionStatus(complete: Bool, titles: Bool, focus: Bool)
    }
    enum WindowNotification: Equatable { case focus, title }

    enum Observation {
        case event(Event)
        case window(AXUIElement, WindowNotification)
    }

    enum ReadResult<Value> {
        case value(Value?)
        case deferred
    }

    struct Subscription {
        let cancel: () -> Void
        let hasFocus: Bool
        let setTitleTracking: (Bool) -> Bool
    }

    typealias Subscribe = (pid_t, @escaping (Observation) -> Void) -> Subscription?
    typealias Resolve = (pid_t, AXUIElement, WindowNotification, () -> Bool) -> ReadResult<Event>

    private let trusted: () -> Bool
    private let subscribe: Subscribe
    private let titleReader: (AXUIElement) -> String?
    private let leftButtonDown: () -> Bool
    private let resolve: Resolve
    let supportsTitles: Bool
    private var worker: Worker?
    private var generation = 0
    private var handler: ((Event) -> Void)?

    var isTrusted: Bool { trusted() }

    static func isLeftButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    init(trusted: @escaping () -> Bool = AXIsProcessTrusted,
         subscribe: @escaping Subscribe = YabaiWindowEvents.subscribeNative,
         titleReader: @escaping (AXUIElement) -> String? = YabaiWindowEvents.readNativeTitle,
         supportsTitles: Bool = YabaiWindowEvents.nativeWindowIDReader != nil,
         leftButtonDown: @escaping () -> Bool = YabaiWindowEvents.isLeftButtonDown,
         resolve: @escaping Resolve = YabaiWindowEvents.resolveWindowNotification) {
        self.trusted = trusted
        self.subscribe = subscribe
        self.titleReader = titleReader
        self.supportsTitles = supportsTitles
        self.leftButtonDown = leftButtonDown
        self.resolve = resolve
    }

    /// Main-thread lifecycle, matching YabaiService.
    func start(_ handler: @escaping (Event) -> Void) {
        stop()
        self.handler = handler
    }

    func update(_ windows: [Window], tracksTitles: Bool = true) {
        guard handler != nil else { return }
        guard trusted() else {
            if worker != nil { stopWorker(); handler?(.permissionLost) }
            return
        }
        var membership: [pid_t: Set<Int>] = [:]
        for window in windows {
            guard let pid = pid_t(exactly: window.pid), pid > 0, pid != getpid() else { continue }
            membership[pid, default: []].insert(window.id)
        }
        if worker == nil {
            let current = generation
            worker = Worker(subscribe: subscribe, leftButtonDown: leftButtonDown, resolve: resolve) { [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    guard let self, current == self.generation else { return }
                    self.handler?(event)
                }
            }
        }
        worker?.perform { $0.update(membership, tracksTitles: tracksTitles) }
    }

    func setTitleDemand(_ enabled: Bool) {
        worker?.perform { $0.setTitleDemand(enabled) }
    }

    func resumeAfterMouseUp() {
        worker?.perform { $0.flushWindowNotifications() }
    }

    @MainActor
    func readTitle(_ element: AXUIElement, automatic: Bool = false) async -> ReadResult<String> {
        guard let worker else { return .value(nil) }
        let current = generation
        let reader = titleReader, leftButtonDown = leftButtonDown
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult<String>, Never>) in
            worker.perform { state in
                guard state.tracksTitles else { continuation.resume(returning: .value(nil)); return }
                guard !automatic || !leftButtonDown() else { continuation.resume(returning: .deferred); return }
                let title = reader(element)
                // Reconciliation can change the service title without an AX event.
                state.invalidateTitle(element)
                continuation.resume(returning: .value(title))
            }
        }
        return current == generation ? result : .value(nil)
    }

    /// Reads an app's focused window on the AX thread after interaction has gone quiet.
    @MainActor
    func readFocusedWindow(pid: pid_t) async -> ReadResult<Int> {
        guard let worker else { return .value(nil) }
        let current = generation
        let leftButtonDown = leftButtonDown
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult<Int>, Never>) in
            worker.perform { _ in
                guard !leftButtonDown() else { continuation.resume(returning: .deferred); return }
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.2)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    continuation.resume(returning: .value(nil)); return
                }
                guard !leftButtonDown() else { continuation.resume(returning: .deferred); return }
                continuation.resume(returning: .value(YabaiWindowEvents.windowID(for: value as! AXUIElement)))
            }
        }
        return current == generation ? result : .value(nil)
    }

    func stop() {
        handler = nil
        stopWorker()
    }

    private func stopWorker() {
        generation += 1
        worker?.stop()
        worker = nil
    }

    deinit { stop() }

    private final class Worker {
        private let state: State
        private let runLoop: CFRunLoop

        init(subscribe: @escaping Subscribe, leftButtonDown: @escaping () -> Bool,
             resolve: @escaping Resolve, handler: @escaping (Event) -> Void) {
            let state = State(subscribe: subscribe, leftButtonDown: leftButtonDown, resolve: resolve, handler: handler)
            self.state = state
            let ready = DispatchSemaphore(value: 0)
            // The thread owns State rather than Worker, so releasing the owner can stop it.
            let thread = Thread {
                let port = Port()
                RunLoop.current.add(port, forMode: .default)
                state.runLoop = CFRunLoopGetCurrent()
                ready.signal()
                CFRunLoopRun()
                state.stop()
            }
            thread.name = "yabai-menu.window-events"
            thread.qualityOfService = .utility
            thread.start()
            ready.wait()
            runLoop = state.runLoop!
        }

        func perform(_ body: @escaping (State) -> Void) {
            let state = state
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { body(state) }
            CFRunLoopWakeUp(runLoop)
        }

        func stop() {
            perform { state in
                state.stop()
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
        }
    }

    private final class State {
        struct Entry {
            let subscription: Subscription
            var windows: Set<Int>
            var titleTracking = false
            var titles: [(AXUIElement, String?)] = []
        }
        private struct PendingNotification {
            let pid: pid_t
            let element: AXUIElement
            let kind: WindowNotification
        }

        var runLoop: CFRunLoop?
        private let subscribe: Subscribe
        private let leftButtonDown: () -> Bool
        private let resolve: Resolve
        private let handler: (Event) -> Void
        private var entries: [pid_t: Entry] = [:]
        private var pending: [PendingNotification] = []
        private var pendingMembership: [pid_t: Set<Int>]?
        private var releaseCheck: Timer?
        private(set) var tracksTitles = true

        init(subscribe: @escaping Subscribe, leftButtonDown: @escaping () -> Bool,
             resolve: @escaping Resolve, handler: @escaping (Event) -> Void) {
            self.subscribe = subscribe
            self.leftButtonDown = leftButtonDown
            self.resolve = resolve
            self.handler = handler
        }

        func setTitleDemand(_ enabled: Bool) {
            guard tracksTitles != enabled else { return }
            tracksTitles = enabled
            pending.removeAll { $0.kind == .title }
            for pid in Array(entries.keys) { entries[pid]?.titles.removeAll() }
            if pending.isEmpty && pendingMembership == nil {
                releaseCheck?.invalidate()
                releaseCheck = nil
            }
        }

        func update(_ membership: [pid_t: Set<Int>], tracksTitles: Bool) {
            setTitleDemand(tracksTitles)
            pendingMembership = membership
            flushWindowNotifications()
        }

        private func applyMembership(_ membership: [pid_t: Set<Int>]) -> Bool {
            var added = false
            defer { if added { handler(.resynchronized) } }
            for pid in Array(entries.keys) where membership[pid] == nil {
                guard !leftButtonDown() else { return false }
                entries.removeValue(forKey: pid)?.subscription.cancel()
                pending.removeAll { $0.pid == pid }
            }
            for (pid, windows) in membership {
                if let old = entries[pid] {
                    if old.windows != windows {
                        entries[pid]?.windows = windows
                        entries[pid]?.titles.removeAll()
                    }
                } else {
                    guard !leftButtonDown() else { return false }
                    if let subscription = subscribe(pid, { [weak self] observation in self?.receive(observation, pid: pid) }) {
                        entries[pid] = Entry(subscription: subscription, windows: windows)
                        added = true
                    }
                }
                if let entry = entries[pid], entry.titleTracking != tracksTitles {
                    guard !leftButtonDown() else { return false }
                    entries[pid]?.titleTracking = entry.subscription.setTitleTracking(tracksTitles)
                }
            }
            let complete = entries.count == membership.count
            handler(.subscriptionStatus(complete: complete,
                                        titles: complete && entries.values.allSatisfy(\.titleTracking),
                                        focus: complete && !entries.isEmpty && entries.values.allSatisfy { $0.subscription.hasFocus }))
            return true
        }

        func invalidateTitle(_ element: AXUIElement) {
            for pid in Array(entries.keys) {
                entries[pid]?.titles.removeAll { CFEqual($0.0, element) }
            }
        }

        private func receive(_ observation: Observation, pid: pid_t) {
            guard let entry = entries[pid] else { return }
            switch observation {
            case .event(let event):
                deliver(event, pid: pid)
            case .window(let element, let kind):
                guard kind != .title || (tracksTitles && entry.titleTracking) else { return }
                // Coalesce by element before reading its window ID. Focus only needs the latest target.
                pending.removeAll {
                    $0.kind == kind && (kind == .focus || ($0.pid == pid && CFEqual($0.element, element)))
                }
                pending.append(PendingNotification(pid: pid, element: element, kind: kind))
                flushWindowNotifications()
            }
        }

        private func resolvePending(_ index: Int) -> Bool {
            let next = pending[index]
            if let membership = pendingMembership, membership[next.pid] == nil {
                pending.remove(at: index)
                return true
            }
            guard case .value(let event) = resolve(next.pid, next.element, next.kind, leftButtonDown) else { return false }
            pending.remove(at: index)
            if let event { deliver(event, pid: next.pid) }
            return true
        }

        func flushWindowNotifications() {
            // A queued subscription or title lookup must not delay the latest focus after release.
            if !leftButtonDown(), let focus = pending.firstIndex(where: { $0.kind == .focus }) {
                _ = resolvePending(focus)
            }
            if let membership = pendingMembership, !leftButtonDown(), applyMembership(membership) {
                pendingMembership = nil
            }
            while !pending.isEmpty, !leftButtonDown() {
                guard resolvePending(pending.startIndex) else { break }
            }
            if pending.isEmpty && pendingMembership == nil {
                releaseCheck?.invalidate()
                releaseCheck = nil
            } else if releaseCheck == nil {
                // Only retry when the mouse-up monitor may have missed a release.
                releaseCheck = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    self?.releaseCheck = nil
                    self?.flushWindowNotifications()
                }
            }
        }

        private func deliver(_ event: Event, pid: pid_t) {
            guard var entry = entries[pid] else { return }
            switch event {
            case .moved, .resynchronized, .permissionLost, .subscriptionStatus:
                handler(event)
            case .focused(_, let owner):
                if owner == pid { handler(event) }
            case .titleChanged(_, let owner, let element, let title):
                guard tracksTitles, entry.titleTracking, owner == pid else { return }
                guard title != nil else {
                    invalidateTitle(element)
                    handler(event)
                    return
                }
                if let index = entry.titles.firstIndex(where: { CFEqual($0.0, element) }) {
                    guard entry.titles[index].1 != title else { return }
                    entry.titles[index].1 = title
                } else {
                    entry.titles.append((element, title))
                }
                entries[pid] = entry
                handler(event)
            }
        }

        func stop() {
            releaseCheck?.invalidate()
            releaseCheck = nil
            pending.removeAll()
            pendingMembership = nil
            for entry in entries.values { entry.subscription.cancel() }
            entries.removeAll()
        }
    }

    private static func subscribeNative(pid: pid_t, handler: @escaping (Observation) -> Void) -> Subscription? {
        let subscription = AXSubscription(handler: handler)
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            Unmanaged<AXSubscription>.fromOpaque(context).takeUnretainedValue().receive(element, notification)
        }, &observer) == .success, let observer else { return nil }
        subscription.observer = observer
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        func add(_ name: String) -> Bool {
            let result = AXObserverAddNotification(observer, application, name as CFString,
                                                   Unmanaged.passUnretained(subscription).toOpaque())
            guard result == .success || result == .notificationAlreadyRegistered else { return false }
            if !subscription.names.contains(name) { subscription.names.append(name) }
            return true
        }

        guard add(kAXWindowMovedNotification) else { return nil }
        let hasFocus = nativeWindowIDReader != nil && add(kAXFocusedWindowChangedNotification)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        return Subscription(cancel: {
            CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(observer))
            for name in subscription.names {
                AXObserverRemoveNotification(observer, application, name as CFString)
            }
        }, hasFocus: hasFocus, setTitleTracking: { enabled in
            let name = kAXTitleChangedNotification
            if enabled { return nativeWindowIDReader != nil && add(name) }
            guard subscription.names.contains(name) else { return false }
            let result = AXObserverRemoveNotification(observer, application, name as CFString)
            if result == .success || result == .notificationNotRegistered {
                subscription.names.removeAll { $0 == name }
                return false
            }
            return true
        })
    }

    private final class AXSubscription {
        var observer: AXObserver?
        var names: [String] = []
        let handler: (Observation) -> Void

        init(handler: @escaping (Observation) -> Void) {
            self.handler = handler
        }

        func receive(_ element: AXUIElement, _ notification: CFString) {
            switch notification as String {
            case kAXWindowMovedNotification: handler(.event(.moved))
            case kAXFocusedWindowChangedNotification: handler(.window(element, .focus))
            case kAXTitleChangedNotification: handler(.window(element, .title))
            default: break
            }
        }
    }

    private static func resolveWindowNotification(pid: pid_t, element: AXUIElement,
                                                  kind: WindowNotification, leftButtonDown: () -> Bool) -> ReadResult<Event> {
        guard !leftButtonDown() else { return .deferred }
        let id = windowID(for: element)
        guard !leftButtonDown() else { return .deferred }
        if kind == .focus { return .value(id.map { .focused(id: $0, pid: pid) }) }
        guard let id else { return .value(.resynchronized) }

        AXUIElementSetMessagingTimeout(element, 0.2)
        var role: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard !leftButtonDown() else { return .deferred }
        guard status == .success else {
            return .value(.titleChanged(id: id, pid: pid, element: element, title: nil))
        }
        guard role as? String == kAXWindowRole else { return .value(nil) }
        return .value(.titleChanged(id: id, pid: pid, element: element, title: readNativeTitle(element)))
    }

    // AX has no public CGWindowID mapping. Use the same optional SPI as yabai, never title/frame guesses.
    typealias WindowIDReader = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32
    private static let nativeWindowIDReader: WindowIDReader? = {
        guard let image = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(image) }
        guard let symbol = dlsym(image, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDReader.self)
    }()

    static func windowID(for element: AXUIElement, using reader: WindowIDReader? = nativeWindowIDReader) -> Int? {
        guard let reader else { return nil }
        var id: CGWindowID = 0
        guard reader(element, &id) == AXError.success.rawValue, id > 0 else { return nil }
        return Int(id)
    }

    private static func readNativeTitle(_ element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        return result == .noValue ? "" : result == .success ? value as? String : nil
    }
}
