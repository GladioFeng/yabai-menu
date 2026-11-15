// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics
import ApplicationServices
import notify

enum YabaiAction: Equatable {
    case focus(spaceID: Int?, window: Int?, expectedPID: Int32? = nil)
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
    private static let windowFieldsWithoutTitle = windowFields.replacingOccurrences(of: ",title,", with: ",")
    nonisolated private static let titleFields = "id,pid,title"
    private static let spaceIdentityFields = "id,index,label,display,type,has-focus,is-visible"
    static let spaceFields = spaceIdentityFields + ",windows"
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
    private var hasDisplayFocusChannel = false
    private var titleToken: Int32?
    private var lastActivatedPID: pid_t?
    private var quietTask: Task<Void, Never>?
    private var deferredSince: UInt64?
    private var deferredPublication = false
    private var resolvingDeferredFocus = false
    private var mouseUpMonitors: [Any] = []
    private let leftButtonDown: () -> Bool
    private var tracksWindowTitles: Bool
    private var titleDemandRevision = 0
    var delayAutomaticFocus: Bool {
        didSet { if oldValue != delayAutomaticFocus { rescheduleDeferredWork() } }
    }
    private var lastActivity: UInt64 = 0
    // Latest concrete window ID and AX owner, plus the independent yabai and activation fallbacks.
    private struct DeferredFocus {
        var id: Int?
        var yabaiID: Int?
        var nativePID: pid_t?
        var activation = false
        var confirmationID: Int?
    }
    private var deferredFocus: DeferredFocus?
    private var deferredScope: RefreshScope?
    private var deferredDisplayFocus = false
    static let quietPeriod: UInt64 = 300_000_000
    static let maxDeferral: UInt64 = 3_000_000_000
    // Keep window_focused registered even when an AX observer accepted focus notifications.
    static let nativeFocusEvents = ["display_changed", "space_changed"]
    enum RefreshScope: Equatable { case focus(Int?, confirmationID: Int? = nil), windows, full }
    private var activeFocusConfirmation: Int?
    private var pendingRefresh: RefreshScope?
    private var pendingRefreshIsAutomatic = false
    private var requestRevision = 0
    private var focusTopologyRevision = 0
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
    private var subscriptionsConfirmed = false
    private var nativeTitlesReady = false
    private var nativeFocusReady = false

    private var needsTitleFallback: Bool {
        tracksWindowTitles && (!usesNativeWindowIDs || !nativeTitlesReady)
    }

    private var receivesYabaiWindowFocus: Bool { signalsReady && focusToken != nil }

    private var usesNativeWindowIDs: Bool {
        observesWindows && windowEvents?.supportsTitles == true && windowEvents?.isTrusted == true
    }
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
         },
         delayAutomaticFocus: Bool = true,
         tracksWindowTitles: Bool = true,
         leftButtonDown: @escaping () -> Bool = YabaiWindowEvents.isLeftButtonDown) {
        self.delayAutomaticFocus = delayAutomaticFocus
        self.tracksWindowTitles = tracksWindowTitles
        self.leftButtonDown = leftButtonDown
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
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
                Task { @MainActor in self?.resumeDeferredAfterMouseUp() }
            }) { mouseUpMonitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
                Task { @MainActor in self?.resumeDeferredAfterMouseUp() }
                return event
            }) { mouseUpMonitors.append(monitor) }
            displaySleeping = !displaysAwake()
            lastActivatedPID = frontmostPID()
            startWindowObservation()
            let workspace = NSWorkspace.shared.notificationCenter
            let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                Task { @MainActor in self?.handleAppNotification(note) }
            }
            observers.append((workspace, activation))
            observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.scheduleActiveSpaceRefresh() }
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
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
        subscriptionsConfirmed = false
        nativeTitlesReady = false
        nativeFocusReady = false
        windowEvents?.start { [weak self] event in
            guard let self, !stopped, !displaySleeping else { return }
            switch event {
            case .moved: scheduleMoveRefresh()
            case .focused(let id, let pid):
                if !receivesYabaiWindowFocus { scheduleFocusRefresh(id, nativePID: pid) }
            case .titleChanged(let id, let pid, let element, let title): applyNativeTitle(id: id, pid: pid, element: element, title: title)
            case .resynchronized: scheduleRefresh()
            case .permissionLost:
                subscriptionsConfirmed = false
                nativeTitlesReady = false
                nativeFocusReady = false
                nativeTitles.removeAll()
                // Re-register yabai's focus/display/Space signals that AX events had replaced.
                reconnect(force: true)
            case .subscriptionStatus(let complete, let titles, let focus):
                let wasFailed = subscriptionsFailed
                let routingChanged = nativeFocusReady != focus || (tracksWindowTitles && nativeTitlesReady != titles)
                nativeTitlesReady = titles
                nativeFocusReady = focus
                subscriptionsConfirmed = true
                subscriptionsFailed = !complete
                updateObservationStatus()
                if complete { completeRecoveryIfHealthy() }
                else { scheduleRetry() }
                if wasFailed != subscriptionsFailed { publish(automatic: true) }
                if routingChanged { reconnect(refreshSnapshot: false) }
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
        scheduleFocusRefresh(nil)
    }

    func setWindowTitleTracking(_ enabled: Bool) {
        guard tracksWindowTitles != enabled else { return }
        let hadTitleFallback = needsTitleFallback
        tracksWindowTitles = enabled
        nativeTitlesReady = false
        titleDemandRevision += 1
        nativeTitles.removeAll()
        if !enabled, var state = snapshot {
            state.windows = state.windows.map { $0.replacingTitle(nil) }
            snapshot = state
        }
        guard !stopped else { return }
        if !enabled { cancelTitleNotification() }
        windowEvents?.setTitleDemand(enabled)
        if hadTitleFallback != needsTitleFallback { reconnect(refreshSnapshot: false) }
        scheduleRefresh()
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
        quietTask?.cancel(); quietTask = nil
        deferredFocus = nil; deferredScope = nil; deferredDisplayFocus = false; deferredSince = nil
        deferredPublication = false
        resolvingDeferredFocus = false
        refreshTask?.cancel(); refreshTask = nil
        pendingRefresh = nil
        activeFocusConfirmation = nil
        hasFullSnapshot = false
        subscriptionsConfirmed = false
        nativeTitles.removeAll()
        debounce?.cancel(); debounce = nil
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

    private func cancelTitleNotification() {
        if let token = titleToken { notify_cancel(token) }
        titleToken = nil
    }

    /// Startup retries are bounded; idle operation never schedules a periodic query.
    func reconnect(force: Bool = false, refreshSnapshot: Bool = true) {
        guard !stopped else { return }
        if connectionTask != nil && !force { return }
        if force { generation += 1; invalidateRefresh(); retryCount = 0; pendingActions.removeAll() }
        updateObservationStatus()
        if refreshSnapshot {
            retry?.cancel()
            retry = nil
        }
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
                let displayFocus = register(notification + ".display-focused", { [weak self] in self?.scheduleActiveDisplayRefresh() })
                hasDisplayFocusChannel = displayFocus != nil
                if let displayFocus { tokens.append(displayFocus) }
                if let token = register(notification + ".window-focused", { [weak self] in
                    guard let self else { return }
                    if let token = focusToken, let id = readFocus(token) { scheduleYabaiWindowFocus(id) }
                    else { scheduleRefresh() }
                }) { focusToken = token; tokens.append(token) }
                // Existing a-bar/skhd hooks already announce layout, float and cross-Space changes.
                if listenForABar, let token = register("user.uid.\(getuid()).com.jeantinland.a-bar.yabai", { [weak self] in self?.scheduleRefresh() }) {
                    tokens.append(token)
                }
            }
            let titleFallback = needsTitleFallback
            let replaced = usesNativeWindowIDs && nativeFocusReady ? Self.nativeFocusEvents : []
            let oldEventError = eventError
            do {
                struct Signal: Decodable { let label: String?; let event: String; let action: String }
                let data = try await run(path, ["-m", "signal", "--list"])
                guard !stopped, current == generation else { return }
                let signals = try JSONDecoder().decode([Signal].self, from: data)
                if titleFallback {
                    if titleToken == nil {
                        titleToken = register(notification + ".window-title-changed", { [weak self] in
                            guard let self, tracksWindowTitles else { return }
                            deferRefresh(.windows)
                        })
                    }
                    if titleToken == nil { notificationsReady = false }
                } else { cancelTitleNotification() }
                for event in ["window_moved", "window_resized"] + (titleFallback ? [] : ["window_title_changed"]) + replaced {
                    let label = "yabai-menu-\(event)"
                    if signals.contains(where: { $0.label == label }) {
                        guard !stopped, current == generation else { throw CancellationError() }
                        _ = try await run(path, ["-m", "signal", "--remove", label])
                    }
                }
                for event in Self.events.filter({ !replaced.contains($0) }) + (titleFallback ? ["window_title_changed"] : []) {
                    let channel = Self.topologyEvents.contains(event) ? notification + ".displays" : notification
                    let action: String
                    if event == "window_focused", focusToken != nil {
                        let focus = notification + ".window-focused"
                        action = "/usr/bin/notifyutil -z 0 -s \(focus) \"$YABAI_WINDOW_ID\" -p \(focus)"
                    } else if event == "display_changed", hasDisplayFocusChannel {
                        action = "/usr/bin/notifyutil -p \(notification).display-focused"
                    } else if event == "window_title_changed" {
                        action = "/usr/bin/notifyutil -z 0 -p \(notification).window-title-changed"
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
            if titleFallback != needsTitleFallback || replaced != (usesNativeWindowIDs && nativeFocusReady ? Self.nativeFocusEvents : []) {
                reconnect(refreshSnapshot: refreshSnapshot)
                return
            }
            if refreshSnapshot || oldEventError != eventError { publish(automatic: true) }
            if refreshSnapshot { refresh(automatic: true) }
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

    // Refresh promptly after an explicit action unless a new mouse hold is in progress.
    func refreshAfterAction() {
        guard !stopped, debounce == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.debounce = nil
            self?.refresh(automatic: true)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // Ported from a-bar's refresh queue: full > windows > latest focus.
    private func enqueueRefresh(_ scope: RefreshScope, automatic: Bool) {
        pendingRefreshIsAutomatic = automatic && (pendingRefresh == nil || pendingRefreshIsAutomatic)
        if scope == .full || pendingRefresh == nil { pendingRefresh = scope }
        else if pendingRefresh != .full, scope == .windows || pendingRefresh != .windows { pendingRefresh = scope }
    }

    // Automatic events: yabai signals, workspace notifications, AX focus/moves and the a-bar hook.
    func scheduleRefresh() { deferRefresh(.full) }
    func scheduleActiveSpaceRefresh() {
        guard !stopped, !displaySleeping else { return }
        focusTopologyRevision &+= 1
        scheduleRefresh()
    }

    func scheduleActiveDisplayRefresh() {
        guard !stopped, !displaySleeping else { return }
        // The yabai display and window notifications can arrive in either order.
        focusTopologyRevision &+= 1
        deferredDisplayFocus = true
        noteDeferredActivity()
    }

    private func scheduleYabaiWindowFocus(_ id: Int) {
        // Preserve the known-ID fast path on systems without native window focus observation.
        guard nativeFocusReady else { scheduleFocusRefresh(id); return }
        if deferredFocus?.confirmationID == id { return }
        if deferredFocus == nil,
           activeFocusConfirmation == id || pendingRefresh == .focus(nil, confirmationID: id) { return }
        if hasFullSnapshot, let current = snapshot?.focusedWindow, current.id == id, current.pid == frontmostPID(),
           deferredFocus == nil, refreshTask == nil, !resolvingDeferredFocus { return }
        queueYabaiFocusConfirmation(id)
    }

    private func queueYabaiFocusConfirmation(_ id: Int) {
        guard !stopped, !displaySleeping else { return }
        deferredFocus = DeferredFocus(confirmationID: id)
        deferRefresh(.focus(nil, confirmationID: id))
    }

    /// `nativePID`: the ID and its owner came from an AX focus event. Apps also report panels, popovers and other
    /// windows yabai does not manage; when such an ID cannot be applied locally it is ignored
    /// instead of costing yabai a focus query plus a full refresh. Real new windows and Space
    /// switches still arrive through yabai's window signals and NSWorkspace.
    func scheduleFocusRefresh(_ id: Int?, nativePID: pid_t? = nil) {
        guard !stopped, !displaySleeping else { return }
        var focus = deferredFocus ?? DeferredFocus()
        if let id {
            focus.id = id; focus.nativePID = nativePID
            if nativePID == nil { focus.yabaiID = id }
        } else { focus.activation = true }
        deferredFocus = focus
        deferRefresh(.focus(id))
    }
    func scheduleMoveRefresh() { deferRefresh(.windows) }

    func deferRefresh(_ scope: RefreshScope) {
        guard !stopped, !displaySleeping else { return }
        if case .focus = scope {
            requestRevision += 1
            if case .focus? = pendingRefresh { pendingRefresh = nil }
            if deferredFocus == nil { deferredFocus = DeferredFocus() }
        } else if deferredScope != .full {
            deferredScope = scope
        }
        noteDeferredActivity()
    }

    private func noteDeferredActivity() {
        lastActivity = DispatchTime.now().uptimeNanoseconds
        if deferredSince == nil { deferredSince = lastActivity }
        scheduleDeferredWork()
    }

    func resumeDeferredAfterMouseUp() {
        guard !leftButtonDown() else { return }
        windowEvents?.resumeAfterMouseUp()
        rescheduleDeferredWork()
    }

    private func rescheduleDeferredWork() {
        quietTask?.cancel()
        quietTask = nil
        scheduleDeferredWork()
    }

    private func scheduleDeferredWork() {
        guard !stopped, !displaySleeping, quietTask == nil, !resolvingDeferredFocus,
              let first = deferredSince else { return }
        let current = generation
        quietTask = Task { [weak self] in
            while let self, !stopped, !displaySleeping, current == generation, !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                let delay = deferredScope != nil || ((deferredFocus != nil || deferredDisplayFocus) && delayAutomaticFocus)
                    ? Self.quietPeriod : 0
                let quiet = now &- lastActivity, waited = now &- first
                let wait: UInt64
                if leftButtonDown() {
                    // A missed mouse-up can only wake the timer while there is work to deliver.
                    wait = Self.quietPeriod
                } else if quiet >= delay || waited >= Self.maxDeferral {
                    quietTask = nil
                    guard refreshTask == nil else { return }
                    let focus = deferredFocus, scope = deferredScope, displayFocus = deferredDisplayFocus
                    deferredFocus = nil; deferredScope = nil; deferredDisplayFocus = false; deferredSince = nil
                    if displayFocus {
                        // Read the actual state instead of inferring focus from an out-of-order signal.
                        refresh(.full, automatic: true)
                    } else if let scope {
                        refresh(focus != nil ? .full : scope, automatic: true)
                    } else if let focus {
                        resolvingDeferredFocus = true
                        await resolveFocus(focus, generation: current)
                        guard current == generation else { return }
                        resolvingDeferredFocus = false
                        flushDeferredPublication()
                        scheduleDeferredWork()
                    } else {
                        flushDeferredPublication()
                    }
                    return
                } else {
                    wait = min(delay - quiet, Self.maxDeferral - waited)
                }
                do { try await Task.sleep(nanoseconds: wait) } catch { return }
            }
        }
    }

    private func flushDeferredPublication() {
        guard deferredPublication, refreshTask == nil, deferredSince == nil else { return }
        publish(automatic: true)
    }

    private func holdAutomaticRefresh(_ scope: RefreshScope, revision: Int) -> Bool {
        guard leftButtonDown() else { return false }
        requeueAutomaticRefresh(scope, revision: revision)
        return true
    }

    private func requeueAutomaticRefresh(_ scope: RefreshScope, revision: Int) {
        if case .focus(let id, let confirmationID) = scope {
            guard revision == requestRevision, deferredFocus == nil else { return }
            if let confirmationID { queueYabaiFocusConfirmation(confirmationID) }
            else { scheduleFocusRefresh(id) }
        } else {
            deferRefresh(scope)
        }
    }

    /// Applies focus to the current snapshot without a yabai query, across displays too, and asks
    /// yabai only when the snapshot cannot prove the result for a yabai or activation event.
    private func resolveFocus(_ focus: DeferredFocus, generation current: Int) async {
        if let confirmationID = focus.confirmationID {
            // Notifyutil child processes can deliver IDs out of order. Ask for the current window.
            refresh(.focus(nil, confirmationID: confirmationID), automatic: true)
            return
        }
        func apply(_ target: Int, owner front: pid_t) -> Bool {
            guard hasFullSnapshot, refreshTask == nil, pendingRefresh == nil, frontmostPID() == front,
                  let next = snapshot?.locallyFocusing(id: target, pid: front) else { return false }
            requestRevision += 1
            if snapshot != next { snapshot = next; status.lastUpdated = Date(); publish(automatic: true) }
            return true
        }
        if let front = frontmostPID() {
            if let id = focus.id, focus.nativePID == nil || focus.nativePID == front, apply(id, owner: front) { return }
            // App activation: ask the app once, on the AX thread, now that interaction has gone quiet.
            if focus.activation, !receivesYabaiWindowFocus {
                let revision = requestRevision
                let result = await windowEvents?.readFocusedWindow(pid: front) ?? .value(nil)
                guard !stopped, !displaySleeping, current == generation, revision == requestRevision else { return }
                guard case .value(let read) = result, !leftButtonDown() else {
                    deferredFocus = focus
                    deferRefresh(.focus(focus.id))
                    return
                }
                if let read, apply(read, owner: front) { return }
            }
        }
        guard !stopped, !displaySleeping, current == generation else { return }
        // An unmanaged AX popup must not erase a simultaneous yabai focus event.
        if focus.nativePID != nil && !focus.activation {
            if let id = focus.yabaiID { refresh(.focus(id), automatic: true) }
            else if let id = focus.id, focus.nativePID == frontmostPID(),
                    snapshot?.windows.contains(where: { $0.id == id && $0.pid == focus.nativePID }) == true {
                refresh(.focus(id), automatic: true)
            }
            return
        }
        refresh(.focus(focus.activation ? nil : focus.id), automatic: true)
    }

    func refresh(_ requestedScope: RefreshScope = .full, automatic: Bool = false) {
        guard !stopped, !displaySleeping else { return }
        if automatic, holdAutomaticRefresh(requestedScope, revision: requestRevision) { return }
        requestRevision += 1
        if requestedScope == .full {
            // A full snapshot covers every deferred event recorded so far.
            quietTask?.cancel(); quietTask = nil
            deferredFocus = nil; deferredScope = nil; deferredDisplayFocus = false; deferredSince = nil
            hasFullSnapshot = false
        }
        enqueueRefresh(requestedScope, automatic: automatic)
        guard refreshTask == nil else { return }
        let current = generation
        refreshTask = Task {
            defer {
                if current == generation {
                    refreshTask = nil
                    activeFocusConfirmation = nil
                    flushDeferredPublication()
                    scheduleDeferredWork()
                }
            }
            while let requested = pendingRefresh {
                guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                let automatic = pendingRefreshIsAutomatic
                pendingRefresh = nil
                let scope = hasFullSnapshot ? requested : .full
                if case .focus(_, let confirmationID) = scope { activeFocusConfirmation = confirmationID }
                else { activeFocusConfirmation = nil }
                let revision = requestRevision, titleRevision = nativeTitleRevision, demand = titleDemandRevision
                let topologyRevision = focusTopologyRevision
                let fields = tracksWindowTitles ? Self.windowFields : Self.windowFieldsWithoutTitle
                if automatic, holdAutomaticRefresh(scope, revision: revision) { continue }
                do {
                    var next: Snapshot
                    var freshWindowID: Int?
                    switch scope {
                    case .focus(let id, _):
                        let data = try await run(path, ["-m", "query", "--windows", fields, "--window"] + (id.map { [String($0)] } ?? []))
                        let window: Window = try await Self.decode(data)
                        guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                        guard revision == requestRevision || pendingRefresh == .focus(window.id) else { continue }
                        guard window.focused, window.pid == frontmostPID(), id == nil || window.id == id,
                              let patched = snapshot?.updatingFocus(window) else { enqueueRefresh(.full, automatic: automatic); continue }
                        next = patched; freshWindowID = window.id
                    case .full:
                        async let displays = run(path, ["-m", "query", "--displays", Self.displayFields])
                        async let spaces = run(path, ["-m", "query", "--spaces", Self.spaceFields])
                        async let windows = run(path, ["-m", "query", "--windows", fields])
                        next = try await Self.decodeSnapshot(spaces: spaces, windows: windows, displays: displays)
                        guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                    case .windows:
                        let data = try await run(path, ["-m", "query", "--windows", fields])
                        let windows: [Window] = try await Self.decode(data)
                        let filtered = windows.filter { $0.pid != getpid() }
                        guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                        guard pendingRefresh != .full, let previous = snapshot, canApplyTitleUpdate(filtered) else {
                            enqueueRefresh(.full, automatic: automatic); continue
                        }
                        next = try Snapshot(spaces: previous.spaces, windows: filtered, displays: previous.displays)
                    }
                    guard demand == titleDemandRevision, topologyRevision == focusTopologyRevision else { continue }
                    if automatic, holdAutomaticRefresh(scope, revision: revision) { continue }
                    guard let reconciled = await reconcileNativeTitles(next, startedAt: titleRevision,
                        freshWindowID: freshWindowID, pruneMissing: scope == .full,
                        generation: current, automatic: automatic) else {
                        guard automatic, !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                        requeueAutomaticRefresh(scope, revision: revision)
                        continue
                    }
                    guard demand == titleDemandRevision, topologyRevision == focusTopologyRevision else { continue }
                    next = reconciled
                    if automatic, holdAutomaticRefresh(scope, revision: revision) { continue }
                    if case .focus = scope, revision != requestRevision {
                        // App activation and the matching window notification can describe the same click.
                        guard let freshWindowID, pendingRefresh == .focus(freshWindowID),
                              next.focusedWindow?.pid == frontmostPID() else { continue }
                        pendingRefresh = nil
                    }
                    if scope == .windows, pendingRefresh == .full { continue }
                    guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                    if scope == .full {
                        hasFullSnapshot = true
                        if observesWindows {
                            subscriptionsConfirmed = false
                            windowEvents?.update(next.windows, tracksTitles: tracksWindowTitles)
                            updateObservationStatus()
                        }
                    }
                    snapshot = next
                    status.lastUpdated = Date()
                    queryError = nil
                    completeRecoveryIfHealthy()
                    publish(automatic: automatic)
                } catch {
                    guard !stopped, !displaySleeping, current == generation, !Task.isCancelled else { return }
                    guard demand == titleDemandRevision, topologyRevision == focusTopologyRevision else { continue }
                    if case .focus = scope, revision != requestRevision { continue }
                    if automatic, holdAutomaticRefresh(scope, revision: revision) { continue }
                    if case .focus = scope {
                        // The desktop has no focused window; confirm with a full snapshot before declaring a disconnect.
                        enqueueRefresh(.full, automatic: automatic)
                        continue
                    }
                    hasFullSnapshot = false
                    queryError = "Cannot read yabai state. \(error.localizedDescription)"
                    publish(automatic: automatic)
                    if scope != .full { enqueueRefresh(.full, automatic: automatic) }
                    else { scheduleRetry() }
                }
            }
        }
    }

    struct WindowTitle: Decodable, Sendable {
        let id: Int
        let pid: Int32
        var title: String?
    }

    /// Menu tracking has its own run loop; the request can run while AppKit is inside it.
    func windowTitleRequest() -> (@Sendable () async -> [Int: WindowTitle])? {
        guard !stopped, !displaySleeping, let snapshot, !snapshot.windows.isEmpty else { return nil }
        let owners = snapshot.windows.reduce(into: [Int: Int32]()) { $0[$1.id] = $1.pid }
        let path = path, run = run
        return {
            // Control-click can open the menu before release; menuDidClose cancels the wait.
            while !Task.isCancelled {
                if !YabaiWindowEvents.isLeftButtonDown() {
                    return await Self.fetchWindowTitles(path: path, run: run, owners: owners)
                }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return [:] }
            }
            return [:]
        }
    }

    func loadWindowTitles(for window: Window) async -> [Int: String] {
        guard !stopped, !displaySleeping, !Task.isCancelled, !leftButtonDown(),
              snapshot?.windows.contains(where: { $0.id == window.id && $0.pid == window.pid }) == true else { return [:] }
        let current = generation
        let titles = await Self.fetchWindowTitles(path: path, run: run, owners: [window.id: window.pid], windowID: window.id)
        guard !stopped, !displaySleeping, !Task.isCancelled, current == generation,
              snapshot?.windows.contains(where: { $0.id == window.id && $0.pid == window.pid }) == true else { return [:] }
        return titles.mapValues { $0.title ?? "" }
    }

    nonisolated private static func fetchWindowTitles(path: String, run: Runner, owners: [Int: Int32],
                                                      windowID: Int? = nil) async -> [Int: WindowTitle] {
        guard !Task.isCancelled, !owners.isEmpty else { return [:] }
        do {
            var args = ["-m", "query", "--windows", titleFields]
            if let windowID { args += ["--window", String(windowID)] }
            let data = try await run(path, args)
            let rows: [WindowTitle]
            if windowID == nil { rows = try await Self.decode(data) }
            else {
                let row: WindowTitle = try await Self.decode(data)
                rows = [row]
            }
            return Dictionary(grouping: rows, by: \.id).compactMapValues { matches in
                guard matches.count == 1, let row = matches.first, row.id > 0, row.pid > 0,
                      owners[row.id] == row.pid else { return nil }
                return row
            }
        } catch { return [:] }
    }

    // Preserve a-bar's title revision/PID reconciliation across in-flight reads.
    func applyNativeTitle(id: Int, pid: pid_t, element: AXUIElement, title: String?) {
        guard tracksWindowTitles, !stopped, !displaySleeping, id > 0, id <= Int(UInt32.max), pid > 0 else { return }
        let matches = snapshot?.windows.indices.filter { snapshot!.windows[$0].id == id } ?? []
        guard matches.count <= 1, matches.first.map({ snapshot!.windows[$0].pid == pid }) ?? true else { return }
        guard let title else { nativeTitles.removeValue(forKey: id); scheduleMoveRefresh(); return }
        nativeTitleRevision += 1
        nativeTitles[id] = NativeTitle(pid: pid, element: element, title: title, revision: nativeTitleRevision)
        guard let index = matches.first else { scheduleRefresh(); return }
        var next = snapshot!
        next.windows[index] = next.windows[index].replacingTitle(title)
        if snapshot != next { snapshot = next; publish(automatic: true) }
    }

    private func reconcileNativeTitles(_ state: Snapshot, startedAt revision: Int,
                                       freshWindowID: Int?, pruneMissing: Bool, generation currentGeneration: Int,
                                       automatic: Bool) async -> Snapshot? {
        guard tracksWindowTitles else { return state }
        var next = state
        for window in state.windows where freshWindowID == nil || window.id == freshWindowID {
            guard let old = nativeTitles[window.id], old.pid == window.pid else { continue }
            if old.title == window.title { nativeTitles.removeValue(forKey: window.id); continue }
            if automatic, leftButtonDown() { return nil }
            let result = await windowEvents?.readTitle(old.element, automatic: automatic) ?? .value(nil)
            guard !stopped, !displaySleeping, currentGeneration == generation, !Task.isCancelled,
                  case .value(let confirmed) = result, !automatic || !leftButtonDown() else { return nil }
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

    func focus(space: Int?, window: Int?, expectedPID: Int32? = nil) {
        let id = space.flatMap { index in snapshot?.spaces.first { $0.index == index }?.id }
        guard space == nil || id != nil else { reportActionError("That Space is no longer available."); return }
        perform(.focus(spaceID: id, window: window, expectedPID: expectedPID))
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
                if !stopped, !displaySleeping, current == generation { refreshAfterAction() }
            }
            actionTask = nil
            status.isSwitching = false
            if !stopped { publish(automatic: true) }
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
        struct Owner: Decodable { let id: Int; let pid: Int32 }
        let ownerQuery = ["-m", "query", "--windows", "id,pid"]
        func readOwner(_ window: Int) async throws -> Owner {
            try await Self.decode(try await run(path, ownerQuery + ["--window", String(window)]))
        }
        func readOwnerIfAvailable(_ window: Int) async throws -> Owner? {
            do { return try await readOwner(window) }
            catch MenuError.windowUnavailable { return nil }
        }
        func readActiveSpaceIfAvailable() async throws -> Space? {
            do { return try await Self.decode(try await run(path, ["-m", "query", "--spaces", Self.spaceIdentityFields, "--space"])) }
            catch MenuError.activeSpaceUnavailable { return nil }
        }
        func validate(_ owner: Owner?, _ window: Int, _ pid: Int32) throws {
            guard let owner, owner.id == window, owner.pid == pid else {
                throw MenuError.message("That window no longer belongs to the selected app.")
            }
        }

        var checkedSpace: Space?
        try check()
        if case .focus(let id, let window?, let pid?) = action {
            if pendingActions.first?.isFocus == true { return }
            guard let state = snapshot, let selected = state.windows.first(where: { $0.id == window && $0.pid == pid }) else {
                throw MenuError.message("That window no longer belongs to the selected app.")
            }
            if id == nil {
                let owner = try await readOwner(window)
                try check()
                if pendingActions.first?.isFocus == true { return }
                try validate(owner, window, pid)
                try await send(["-m", "window", "--focus", String(window)])
                return
            }
            if let space = state.focusedSpace, space.id == id, space.visible,
               selected.space == space.index, selected.visible == true, !selected.sticky, !selected.hidden, !selected.minimized {
                let revision = focusTopologyRevision
                async let active = readActiveSpaceIfAvailable()
                async let owner = readOwnerIfAvailable(window)
                let (live, liveOwner) = try await (active, owner)
                try check()
                if pendingActions.first?.isFocus == true { return }
                if let liveOwner { try validate(liveOwner, window, pid) }
                // Query the active Space's stable ID; another display's Space can still be visible.
                if let live, revision == focusTopologyRevision, live.id == space.id, live.index > 0,
                   live.display == space.display, live.focused, live.visible {
                    guard liveOwner != nil else { throw MenuError.windowUnavailable }
                    checkedSpace = live
                }
            }
        }
        let spaces: [Space]
        if let checkedSpace {
            spaces = [checkedSpace]
        } else {
            // Space indices change after swaps and deletion; resolve a stable ID immediately before acting.
            let data = try await run(path, ["-m", "query", "--spaces"])
            try check()
            spaces = try Snapshot(spaces: data, windows: Data("[]".utf8)).spaces
        }
        func target(_ id: Int) throws -> Space {
            guard let space = spaces.first(where: { $0.id == id }) else {
                throw MenuError.message("That Space no longer exists. Choose it again from the updated menu.")
            }
            return space
        }
        switch action {
        case .focus(let id, let window, let pid):
            func validateOwner(_ window: Int, _ pid: Int32, beforeSpaceSwitch: Bool = false) async throws {
                let owner: Owner?
                if beforeSpaceSwitch {
                    // An off-space window may appear in the list without a targeted AX reference yet.
                    let rows: [Owner] = try await Self.decode(try await run(path, ownerQuery))
                    let matches = rows.filter { $0.id == window }
                    owner = matches.count == 1 ? matches.first : nil
                } else {
                    owner = try await readOwner(window)
                }
                try check()
                try validate(owner, window, pid)
            }
            if pendingActions.first?.isFocus == true { return }
            let space = try id.map(target)
            let needsPreflightList = space?.focused == false
            if checkedSpace == nil, let window, let pid {
                try await validateOwner(window, pid, beforeSpaceSwitch: needsPreflightList)
                if pendingActions.first?.isFocus == true { return }
            }
            var switchedSpace = false
            if let space {
                // yabai rejects Space focus during Mission Control, even when that Space is already active.
                do {
                    try await send(["-m", "space", "--focus", String(space.index)])
                    switchedSpace = true
                } catch MenuError.alreadyFocusedSpace { try check() }
            }
            if pendingActions.first?.isFocus == true { return }
            if let window {
                if let pid, switchedSpace || needsPreflightList {
                    try await validateOwner(window, pid)
                    if pendingActions.first?.isFocus == true { return }
                }
                try await send(["-m", "window", "--focus", String(window)])
            }
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

    var diagnosticLines: [String] {
        let trusted = windowEvents?.isTrusted
        let subscriptions: String
        if stopped { subscriptions = "stopped" }
        else if displaySleeping { subscriptions = "suspended" }
        else if windowEvents == nil { subscriptions = "unavailable" }
        else if !observesWindows { subscriptions = "not started" }
        else if trusted != true { subscriptions = "permission required" }
        else if !hasFullSnapshot || !subscriptionsConfirmed { subscriptions = "pending" }
        else { subscriptions = subscriptionsFailed ? "failed" : "active" }

        // 命令错误可能含窗口标题或凭据，诊断只导出固定类别。
        let errors = [(queryError, "state query failed"), (eventError, "signal/notification setup failed"),
                      (monitorError, "daemon monitor failed"), (windowObservationError, "native window observation unavailable"),
                      (status.actionError, "Space/window action failed")].compactMap { $0.0 == nil ? nil : $0.1 }
        return ["Accessibility: \(trusted.map { $0 ? "granted" : "denied" } ?? "unavailable")",
                "Native window subscriptions: \(subscriptions)",
                "Yabai signals: \(stopped ? "stopped" : (signalsReady ? "ready" : "not ready"))",
                "Refresh notifications: \(notificationsReady ? "ready" : "not ready")",
                "Daemon monitor: \(stopped ? "stopped" : (monitorError != nil ? "failed" : (daemonMonitor == nil ? "not started" : "active")))",
                "Errors: \(errors.isEmpty ? "none" : errors.joined(separator: "; "))"]
    }

    private func publish(automatic: Bool = false) {
        if automatic, leftButtonDown() {
            deferredPublication = true
            noteDeferredActivity()
            return
        }
        if deferredPublication, deferredFocus == nil, deferredScope == nil, !deferredDisplayFocus {
            quietTask?.cancel(); quietTask = nil; deferredSince = nil
        }
        deferredPublication = false
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
        windowEvents?.stop()
        observesWindows = false
        subscriptionsFailed = false
        daemonMonitor?.stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        mouseUpMonitors.forEach(NSEvent.removeMonitor)
        mouseUpMonitors.removeAll()
        tokens.forEach { notify_cancel($0) }
        tokens.removeAll()
        focusToken = nil
        cancelTitleNotification()
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
