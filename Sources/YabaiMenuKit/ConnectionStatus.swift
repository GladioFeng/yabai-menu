// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ConnectionStatus: Equatable {
    enum Mode: String { case connecting, live, limited, disconnected, suspended }
    var mode: Mode = .connecting
    var detail: String?
    var actionError: String?
    var lastUpdated: Date?
    var isSwitching = false

    var title: String {
        switch mode {
        case .connecting: return "Connecting…"
        case .live: return "Event-driven · Connected"
        case .limited: return "Event connection needs attention"
        case .disconnected: return lastUpdated == nil ? "Disconnected" : "Disconnected · Showing last known state"
        case .suspended: return "Display asleep · Updates resume on wake"
        }
    }

    var message: String? { actionError ?? detail }
    var needsAttention: Bool { mode == .limited || mode == .disconnected || actionError != nil }

    func updatedDescription(now: Date = Date()) -> String {
        guard let lastUpdated else { return "No successful update yet" }
        let seconds = max(0, Int(now.timeIntervalSince(lastUpdated)))
        return seconds < 60 ? "Updated \(seconds)s ago" : "Updated \(seconds / 60)m ago"
    }
}
