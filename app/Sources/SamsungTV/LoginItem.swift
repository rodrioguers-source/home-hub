import Foundation
import Observation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp`. It registers whatever bundle is running,
/// so the app should stay at the same path once enabled.
@MainActor
@Observable
final class LoginItem {
    private(set) var enabled = false
    private(set) var needsApproval = false
    private(set) var error: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't \(on ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }
}
