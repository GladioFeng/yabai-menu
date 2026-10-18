// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics
import ApplicationServices
import notify

enum YabaiAction: Equatable {
    case focus(spaceID: Int?, window: Int?)
    case rename(spaceID: Int, label: String)
    case move(spaceID: Int, offset: Int)
    case create(anchorID: Int)
    case remove(spaceID: Int)
    var isFocus: Bool { if case .focus = self { return true }; return false }
}

@MainActor
final class YabaiClient {
    typealias Runner = (String, [String]) async throws -> Data
    typealias Register = (String, @escaping () -> Void) -> Int32?
    static let events = ["space_changed", "space_created", "space_destroyed", "display_changed",
                         "display_added", "display_removed", "display_moved", "display_resized",
                         "window_focused", "window_created", "window_destroyed",
                         "window_minimized", "window_deminimized",
                         "mission_control_exit", "dock_did_restart"]
    static let ownedEvents = events + ["window_moved", "window_resized", "window_title_changed"]
    static let topologyEvents = Set(["display_added", "display_removed", "display_moved", "display_resized"])
    // Full window serialization includes WindowServer reads unrelated to this UI.
    static let windowFields = "id,pid,app,title,subrole,display,space,has-focus,is-visible,is-floating,is-sticky,is-hidden,is-minimized,stack-index,frame"
    static let spaceFields = "id,index,label,display,type,has-focus,is-visible,windows"
    static let displayFields = "id,index,uuid,has-focus"
    static let refreshName = "user.uid.\(getuid()).dev.gladio.yabai-menu.refresh"

    let path: String
    var onUpdate: ((Snapshot?, ConnectionStatus) -> Void)?
    private(set) var snapshot: Snapshot?
    private(set) var status = ConnectionStatus()
    private let run: Runner
    private let register: Register
    private let displaysAwake: () -> Bool
    private let windowEvents: YabaiWindowEvents?
    private let frontmostPID: () -> pid_t?
    private let readFocus: (Int32) -> Int?
    private let notification: String
    private let listenForABar: Bool
    private var tokens: [Int32] = []
    private var notificationsReady = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var daemonMonitor: DaemonMonitor?
    private var observesWindows = false
    private var focusToken: Int32?
    private var lastActivatedPID: pid_t?
    private var moveRefreshTask: Task<Void, Never>?
    enum RefreshScope: Equatable { case focus(Int?), windows, full }
    private var pendingRefresh: RefreshScope?
    private var requestRevision = 0
    private var hasFullSnapshot = false
    private struct NativeTitle {
        let pid: pid_t
        let element: AXUIElement
        var title: String
        var revision: Int
    }
    private var nativeTitles: [Int: NativeTitle] = [:]
    private var nativeTitleRevision = 0
    private var debounce: DispatchWorkItem?
    private var retry: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var pendingActions: [YabaiAction] = []
    private var generation = 0
    private var retryCount = 0
    private var stopped = true
    private var signalsReady = false
    private var queryError: String?
    private var eventError: String?
    private var monitorError: String?
    private var windowObservationError: String?
    private var subscriptionsFailed = false
    private var displaySleeping = false

    init(path: String, notification: String? = nil,
         run: @escaping Runner = { try await Command.run($0, $1) },
         register: Register? = nil,
         windowEvents: YabaiWindowEvents? = YabaiWindowEvents(),
         frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         readFocus: @escaping (Int32) -> Int? = { token in
             var id: UInt64 = 0
             guard notify_get_state(token, &id) == NOTIFY_STATUS_OK, id > 0, id <= UInt64(UInt32.max) else { return nil }
             return Int(id)
         },
         displaysAwake: @escaping () -> Bool = {
             var active: UInt32 = 0
             CGGetActiveDisplayList(0, nil, &active)
             return active > 0
         }) {
        self.path = path
        self.run = run
        self.register = register ?? Self.registerNotification
        self.displaysAwake = displaysAwake
        self.windowEvents = windowEvents
        self.frontmostPID = frontmostPID
        self.readFocus = readFocus
        self.notification = notification ?? Self.refreshName
        listenForABar = notification == nil
    }

    func start(observeSystem: Bool = true) {
        guard stopped else { return }
        stopped = false
        if observeSystem {
            displaySleeping = !displaysAwake()
            lastActivatedPID = frontmostPID()
            startWindowObservation()
            let workspace = NSWorkspace.shared.notificationCenter
            let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handleAppNotification(note) }
            }
            observers.append((workspace, activation))
            for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
                observe(workspace, name) { [weak self] in self?.scheduleRefresh() }
            }
            observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.reconnect(force: true) }
            observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.screenChanged(sleeping: false) }
            observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.screenChanged(sleeping: true) }
            observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.displayConfigurationChanged() }
            let monitor = DaemonMonitor { [weak self] identity in self?.daemonChanged(available: identity != nil) }
            daemonMonitor = monitor
            do { try monitor.start() }
            catch { monitorError = error.localizedDescription }
        }
        reconnect()
    }

    func startWindowObservation() {
        observesWindows = true
        windowEvents?.start { [weak self] event in
            guard let self, !stopped, !displaySleeping else { return }
            switch event {
            case .moved: scheduleMoveRefresh()
            case .titleChanged(let id, let pid, let element, let title): applyNativeTitle(id: id, pid: pid, element: element, title: title)
            case .resynchronized: refresh()
            case .permissionLost:
                nativeTitles.removeAll()
                refresh()
            case .subscriptionStatus(let complete):
                let wasFailed = subscriptionsFailed
                subscriptionsFailed = !complete
                updateObservationStatus()
                if complete { completeRecoveryIfHealthy() }
                else { scheduleRetry() }
                if wasFailed != subscriptionsFailed { publish() }
            }
        }
        updateObservationStatus()
    }

    // Same activation deduplication and targeted focus path as a-bar.
    func handleAppNotification(_ note: Notification) {
        guard !stopped else { return }
        let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? frontmostPID()
        guard pid != lastActivatedPID else { return }
        lastActivatedPID = pid
        refresh(.focus(nil))
    }

    func requestWindowObservationAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func updateObservationStatus() {
        guard observesWindows else { return }
        if windowEvents?.isTrusted != true {
            windowObservationError = "Native window updates need Accessibility access. Enable it in Settings, then Check Connection."
        } else {
            windowObservationError = subscriptionsFailed ? "Native window updates could not subscribe to every app. Use Check Connection to retry." : nil
        }
    }

    private func completeRecoveryIfHealthy() {
        guard hasFullSnapshot, queryError == nil, signalsReady, notificationsReady,
              monitorError == nil, windowObservationError == nil else { return }
        retryCount = 0
        retry?.cancel(); retry = nil
    }

    private func invalidateRefresh() {
        moveRefreshTask?.cancel(); moveRefreshTask = nil
        refreshTask?.cancel(); refreshTask = nil
        pendingRefresh = nil
        hasFullSnapshot = false
        nativeTitles.removeAll()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
        observers.append((center, observer))
    }

    func daemonChanged(available: Bool) {
        guard !stopped else { return }
        generation += 1
        invalidateRefresh()
        pendingActions.removeAll()
        retry?.cancel()
        signalsReady = false
        if available { reconnect(force: true) }
        else {
            queryError = "yabai is not running. Start yabai, or use Check Connection."
            publish()
        }
    }

    func screenChanged(sleeping: Bool) {
        guard !stopped else { return }
        displaySleeping = sleeping
        if sleeping {
            generation += 1
            invalidateRefresh()
            pendingActions.removeAll()
            retry?.cancel()
            retry = nil
            publish()
        } else { reconnect(force: true) }
    }

    func displayConfigurationChanged() {
        let sleeping = !displaysAwake()
        if sleeping != displaySleeping { screenChanged(sleeping: sleeping) }
        else { reconnect(force: true) }
    }

    /// Startup retries are bounded; idle operation never schedules a periodic query.
    func reconnect(force: Bool = false) {
        guard !stopped else { return }
        if connectionTask != nil && !force { return }
        if force { generation += 1; invalidateRefresh(); retryCount = 0; pendingActions.removeAll() }
        updateObservationStatus()
        retry?.cancel()
        retry = nil
        let previous = connectionTask
        let current = generation
        connectionTask = Task {
            await previous?.value
            guard !stopped, current == generation else { return }
            if !notificationsReady {
                tokens.forEach { notify_cancel($0) }
                tokens.removeAll()
                focusToken = nil
                if let token = register(notification, { [weak self] in self?.scheduleRefresh() }) {
                    tokens.append(token)
                    notificationsReady = true
                }
                else { eventError = "Cannot receive refresh notifications. Use Check Connection to retry." }
                if let token = register(notification + ".displays", { [weak self] in self?.displayConfigurationChanged() }) {
                    tokens.append(token)
                } else { notificationsReady = false; eventError = "Cannot receive display notifications." }
                if let token = register(notification + ".window-focused", { [weak self] in
                    guard let self else { return }
                    if let token = focusToken, let id = readFocus(token) { refresh(.focus(id)) }
                    else { refresh() }
                }) { focusToken = token; tokens.append(token) }
                if let token = register(notification + ".window-title-changed", { [weak self] in self?.refresh(.windows) }) {
                    tokens.append(token)
                } else if windowEvents?.supportsTitles == false { notificationsReady = false }
                // Existing a-bar/skhd hooks already announce layout, float and cross-Space changes.
                if listenForABar, let token = register("user.uid.\(getuid()).com.jeantinland.a-bar.yabai", { [weak self] in self?.scheduleRefresh() }) {
                    tokens.append(token)
                }
            }
            do {
                struct Signal: Decodable { let label: String?; let event: String; let action: String }
                let data = try await run(path, ["-m", "signal", "--list"])
                let signals = try JSONDecoder().decode([Signal].self, from: data)
                // Old per-move signals fork a shell for every mouse movement; only retire our own labels.
                let titleFallback = windowEvents?.supportsTitles == false
                for event in ["window_moved", "window_resized"] + (titleFallback ? [] : ["window_title_changed"]) {
                    let label = "yabai-menu-\(event)"
                    if signals.contains(where: { $0.label == label }) {
                        guard !stopped, current == generation else { throw CancellationError() }
                        _ = try await run(path, ["-m", "signal", "--remove", label])
                    }
                }
                for event in Self.events + (titleFallback ? ["window_title_changed"] : []) {
                    let channel = Self.topologyEvents.contains(event) ? notification + ".displays" : notification
                    let action: String
                    if event == "window_focused", focusToken != nil {
                        let focus = notification + ".window-focused"
                        action = "/usr/bin/notifyutil -z 0 -s \(focus) \"$YABAI_WINDOW_ID\" -p \(focus)"
                    } else if event == "window_title_changed" {
                        action = "/usr/bin/notifyutil -p \(notification).window-title-changed"
                    } else { action = "/usr/bin/notifyutil -p \(channel)" }
                    guard !stopped, current == generation else { throw CancellationError() }
                    let label = "yabai-menu-\(event)"
                    if signals.contains(where: { $0.label == label && $0.event == event && $0.action == action }) { continue }
                    // yabai replaces an existing signal with the same label atomically.
                    _ = try await run(path, ["-m", "signal", "--add", "event=\(event)", "action=\(action)", "label=\(label)"])
                }
                guard !stopped, current == generation else { return }
                signalsReady = true
                eventError = notificationsReady ? nil : "Cannot receive refresh notifications."
                if !notificationsReady { scheduleRetry() }
            } catch {
                guard !stopped, current == generation else { return }
                signalsReady = false
                eventError = "Event registration failed. \(error.localizedDescription)"
                scheduleRetry()
            }
            guard !stopped, current == generation else { return }
            connectionTask = nil
            publish()
            refresh()
        }
    }

    private func scheduleRetry() {
        guard retry == nil, retryCount < 3 else { return }
        let delay = UInt64(1 << retryCount) * 1_000_000_000
        retryCount += 1
        retry = Task {
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !stopped, !Task.isCancelled else { return }
            retry = nil
            reconnect()
        }
    }

    func scheduleRefresh() {
        guard !stopped, debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.refresh()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // Ported from a-bar's refresh queue: full > windows > latest focus.
    private func enqueueRefresh(_ scope: RefreshScope) {
        if scope == .full || pendingRefresh == nil { pendingRefresh = scope }
        else if pendingRefresh != .full, scope == .windows || pendingRefresh != .windows { pendingRefresh = scope }
    }

    func scheduleMoveRefresh() {
        guard !stopped, !displaySleeping else { return }
        moveRefreshTask?.cancel()
        let current = generation
        moveRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, !stopped, current == generation, !Task.isCancelled else { return }
            moveRefreshTask = nil
            refresh()
        }
    }

    func refresh(_ requestedScope: RefreshScope = .full) {
        guard !stopped, !displaySleeping else { return }
        requestRevision += 1
        if requestedScope == .full { moveRefreshTask?.cancel(); moveRefreshTask = nil; hasFullSnapshot = false }
        enqueueRefresh(requestedScope)
        guard refreshTask == nil else { return }
        let current = generation
        refreshTask = Task {
            defer { if current == generation { refreshTask = nil } }
            while let requested = pendingRefresh {
                guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                pendingRefresh = nil
                let scope = hasFullSnapshot ? requested : .full
                if scope == .full { moveRefreshTask?.cancel(); moveRefreshTask = nil }
                let revision = requestRevision, titleRevision = nativeTitleRevision
                do {
                    var next: Snapshot
                    var freshWindowID: Int?
                    switch scope {
                    case .focus(let id):
                        let data = try await run(path, ["-m", "query", "--windows", Self.windowFields, "--window"] + (id.map { [String($0)] } ?? []))
                        let window: Window = try await Self.decode(data)
                        guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                        guard revision == requestRevision else { continue }
                        guard window.focused, window.pid == frontmostPID(), id == nil || window.id == id,
                              let patched = snapshot?.updatingFocus(window) else { enqueueRefresh(.full); continue }
                        next = patched; freshWindowID = window.id
                    case .full:
                        async let displays = run(path, ["-m", "query", "--displays", Self.displayFields])
                        async let spaces = run(path, ["-m", "query", "--spaces", Self.spaceFields])
                        async let windows = run(path, ["-m", "query", "--windows", Self.windowFields])
                        next = try await Self.decodeSnapshot(spaces: spaces, windows: windows, displays: displays)
                        guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                    case .windows:
                        let data = try await run(path, ["-m", "query", "--windows", Self.windowFields])
                        let windows: [Window] = try await Self.decode(data)
                        let filtered = windows.filter { $0.pid != getpid() }
                        guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                        guard pendingRefresh != .full, let previous = snapshot, canApplyTitleUpdate(filtered) else {
                            enqueueRefresh(.full); continue
                        }
                        next = try Snapshot(spaces: previous.spaces, windows: filtered, displays: previous.displays)
                    }
                    guard let reconciled = await reconcileNativeTitles(next, startedAt: titleRevision,
                        freshWindowID: freshWindowID, pruneMissing: scope == .full, generation: current) else { return }
                    next = reconciled
                    if case .focus = scope, revision != requestRevision { continue }
                    if scope == .windows, pendingRefresh == .full { continue }
                    guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                    if scope == .full {
                        hasFullSnapshot = true
                        if observesWindows { windowEvents?.update(next.windows); updateObservationStatus() }
                    }
                    snapshot = next
                    status.lastUpdated = Date()
                    queryError = nil
                    completeRecoveryIfHealthy()
                    publish()
                } catch {
                    guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                    if case .focus = scope, revision != requestRevision { continue }
                    if case .focus = scope {
                        // The desktop has no focused window; confirm with a full snapshot before declaring a disconnect.
                        enqueueRefresh(.full)
                        continue
                    }
                    hasFullSnapshot = false
                    queryError = "Cannot read yabai state. \(error.localizedDescription)"
                    publish()
                    if scope != .full { enqueueRefresh(.full) }
                    else { scheduleRetry() }
                }
            }
        }
    }

    // Preserve a-bar's title revision/PID reconciliation across in-flight reads.
    func applyNativeTitle(id: Int, pid: pid_t, element: AXUIElement, title: String?) {
        guard !stopped, !displaySleeping, id > 0, id <= Int(UInt32.max), pid > 0 else { return }
        let matches = snapshot?.windows.indices.filter { snapshot!.windows[$0].id == id } ?? []
        guard matches.count <= 1, matches.first.map({ snapshot!.windows[$0].pid == pid }) ?? true else { return }
        guard let title else { nativeTitles.removeValue(forKey: id); refresh(.windows); return }
        nativeTitleRevision += 1
        nativeTitles[id] = NativeTitle(pid: pid, element: element, title: title, revision: nativeTitleRevision)
        guard let index = matches.first else { refresh(); return }
        var next = snapshot!
        next.windows[index] = next.windows[index].replacingTitle(title)
        if snapshot != next { snapshot = next; publish() }
    }

    private func reconcileNativeTitles(_ state: Snapshot, startedAt revision: Int,
                                       freshWindowID: Int?, pruneMissing: Bool, generation currentGeneration: Int) async -> Snapshot? {
        var next = state
        for window in state.windows where freshWindowID == nil || window.id == freshWindowID {
            guard let old = nativeTitles[window.id], old.pid == window.pid else { continue }
            if old.title == window.title { nativeTitles.removeValue(forKey: window.id); continue }
            let confirmed = await windowEvents?.readTitle(old.element)
            guard !stopped, !displaySleeping, currentGeneration == generation, !Task.isCancelled else { return nil }
            guard var current = nativeTitles[window.id], current.revision == old.revision else { continue }
            guard let confirmed else { nativeTitles.removeValue(forKey: window.id); continue }
            if current.title != confirmed {
                nativeTitleRevision += 1; current.title = confirmed; current.revision = nativeTitleRevision
                nativeTitles[window.id] = current
            }
            if confirmed == window.title { nativeTitles.removeValue(forKey: window.id) }
        }
        for index in next.windows.indices {
            let window = next.windows[index]
            if let title = nativeTitles[window.id], title.pid == window.pid { next.windows[index] = window.replacingTitle(title.title) }
        }
        if pruneMissing {
            nativeTitles = nativeTitles.filter { id, title in
                title.revision > revision || next.windows.contains { $0.id == id && $0.pid == title.pid }
            }
        }
        return next
    }

    private func canApplyTitleUpdate(_ windows: [Window]) -> Bool {
        guard let snapshot, snapshot.windows.count == windows.count else { return false }
        var previous: [Int: Window] = [:]
        for window in snapshot.windows { guard previous.updateValue(window, forKey: window.id) == nil else { return false } }
        for window in windows {
            guard let old = previous.removeValue(forKey: window.id), old.pid == window.pid,
                  old.space == window.space, old.display == window.display, old.focused == window.focused,
                  old.visible == window.visible, old.minimized == window.minimized,
                  old.hidden == window.hidden, old.sticky == window.sticky else { return false }
        }
        return previous.isEmpty
    }

    nonisolated private static func decode<T: Decodable>(_ data: Data) async throws -> T {
        try Task.checkCancellation()
        return try Snapshot.decode(T.self, from: data)
    }

    nonisolated private static func decodeSnapshot(spaces: Data, windows: Data, displays: Data) async throws -> Snapshot {
        try Task.checkCancellation()
        return try Snapshot(spaces: spaces, windows: windows, displays: displays, excludingPID: getpid())
    }

    func focus(space: Int?, window: Int?) {
        let id = space.flatMap { index in snapshot?.spaces.first { $0.index == index }?.id }
        guard space == nil || id != nil else { reportActionError("That Space is no longer available."); return }
        perform(.focus(spaceID: id, window: window))
    }

    func perform(_ action: YabaiAction) {
        guard !stopped, !displaySleeping, status.mode == .live || status.mode == .limited else { return }
        if action.isFocus, pendingActions.last?.isFocus == true { pendingActions.removeLast() }
        pendingActions.append(action)
        status.actionError = nil
        guard actionTask == nil else { publish(); return }
        status.isSwitching = true
        publish()
        actionTask = Task {
            while !stopped, !displaySleeping, !pendingActions.isEmpty {
                let current = generation
                let next = pendingActions.removeFirst()
                do { try await execute(next, generation: current) }
                catch is CancellationError { }
                catch {
                    if !stopped, current == generation { status.actionError = "The selected action failed. \(error.localizedDescription)" }
                }
                // A display focus may have succeeded even if the following mutation failed.
                if !stopped, !displaySleeping, current == generation { scheduleRefresh() }
            }
            actionTask = nil
            status.isSwitching = false
            if !stopped { publish() }
        }
    }

    private func execute(_ action: YabaiAction, generation current: Int) async throws {
        func check() throws {
            guard !stopped, !displaySleeping, generation == current else { throw CancellationError() }
        }
        func send(_ args: [String]) async throws {
            try check()
            _ = try await run(path, args)
            try check()
        }
        // Space indices change after swaps and deletion; resolve a stable ID immediately before acting.
        try check()
        let data = try await run(path, ["-m", "query", "--spaces"])
        try check()
        let spaces = try Snapshot(spaces: data, windows: Data("[]".utf8)).spaces
        func target(_ id: Int) throws -> Space {
            guard let space = spaces.first(where: { $0.id == id }) else {
                throw MenuError.message("That Space no longer exists. Choose it again from the updated menu.")
            }
            return space
        }
        switch action {
        case .focus(let id, let window):
            if let id {
                let space = try target(id)
                do { try await send(["-m", "space", "--focus", String(space.index)]) }
                catch MenuError.alreadyFocusedSpace { try check() }
            }
            if pendingActions.first?.isFocus == true { return }
            if let window { try await send(["-m", "window", "--focus", String(window)]) }
        case .rename(let id, let label):
            let space = try target(id)
            guard label.utf8.count <= 1024, !label.contains("\0") else { throw MenuError.message("The Space label is too long or contains an invalid character.") }
            try await send(["-m", "space", String(space.index), "--label", label])
        case .move(let id, let offset):
            let space = try target(id)
            guard [-1, 1].contains(offset), let position = spaces.firstIndex(where: { $0.id == id }),
                  spaces.indices.contains(position + offset) else { throw MenuError.message("There is no Space in that direction.") }
            try await send(["-m", "space", String(space.index), "--swap", String(spaces[position + offset].index)])
        case .create(let anchorID):
            let space = try target(anchorID)
            try await send(["-m", "display", "--focus", String(space.display)])
            try await send(["-m", "space", "--create"])
        case .remove(let id):
            let space = try target(id)
            try await send(["-m", "display", "--focus", String(space.display)])
            let updated = try await run(path, ["-m", "query", "--spaces"])
            try check()
            guard let currentSpace = try Snapshot(spaces: updated, windows: Data("[]".utf8)).spaces.first(where: { $0.id == id }),
                  currentSpace.display == space.display else { throw MenuError.message("That Space changed while the display was being focused. Please try again.") }
            try await send(["-m", "space", String(currentSpace.index), "--destroy"])
        }
    }

    func dismissActionError() { status.actionError = nil; publish() }
    func reportActionError(_ message: String) { status.actionError = message; publish() }

    private func publish() {
        status.mode = displaySleeping ? .suspended : (queryError != nil ? .disconnected : (snapshot == nil ? .connecting : (signalsReady && notificationsReady && monitorError == nil && windowObservationError == nil ? .live : .limited)))
        status.detail = displaySleeping ? nil : (queryError ?? eventError ?? monitorError ?? windowObservationError)
        onUpdate?(snapshot, status)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        generation += 1
        let previousRefresh = refreshTask
        invalidateRefresh()
        pendingActions.removeAll()
        retry?.cancel()
        retry = nil
        debounce?.cancel()
        debounce = nil
        windowEvents?.stop()
        observesWindows = false
        subscriptionsFailed = false
        daemonMonitor?.stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        tokens.forEach { notify_cancel($0) }
        tokens.removeAll()
        focusToken = nil
        notificationsReady = false
        await connectionTask?.value
        await previousRefresh?.value
        await actionTask?.value
        connectionTask = nil
        refreshTask = nil
        actionTask = nil
        await withTaskGroup(of: Void.self) { group in
            for event in Self.ownedEvents {
                let path = path, run = run
                group.addTask { _ = try? await run(path, ["-m", "signal", "--remove", "yabai-menu-\(event)"]) }
            }
        }
    }

    private static func registerNotification(_ name: String, handler: @escaping () -> Void) -> Int32? {
        var token: Int32 = -1
        let result = notify_register_dispatch(name, &token, .main) { _ in Task { @MainActor in handler() } }
        return result == NOTIFY_STATUS_OK ? token : nil
    }
}
