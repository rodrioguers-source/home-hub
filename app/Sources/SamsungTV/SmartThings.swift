import Foundation
import Observation

enum STConfig {
    static let pollWhileOn: Double = 45
    static let pollWhileOff: Double = 300
}

struct STOption: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
        let name = try c.decodeIfPresent(String.self, forKey: .name)
        self.id = id ?? name ?? ""
        self.name = name ?? id ?? ""
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    /// The TV reports the active input by id but picture/sound modes by name, so match either.
    func matches(_ value: String?) -> Bool { value != nil && (value == id || value == name) }
}

enum STModeKind: String { case picture, sound }

struct STStatus: Decodable, Sendable {
    var health: String?
    var power: String?
    var inputSource: String?
    var inputs: [STOption]?
    var pictureMode: String?
    var pictureModes: [STOption]?
    var soundMode: String?
    var soundModes: [STOption]?
    var volume: Double?
    var mute: String?
    var tvChannelName: String?
    var tvChannel: String?

    var online: Bool { health?.uppercased() != "OFFLINE" }
}

/// Samsung's cloud view of the TV, through the helper's st.* methods. After any failure it stops
/// polling until `retry()`, so a locked 1Password never turns into a loop of Touch ID prompts.
@MainActor
@Observable
final class SmartThingsModel {
    enum Phase: Equatable { case idle, ready, unavailable(String) }

    var phase: Phase = .idle
    var status: STStatus?
    var fetchedAt: Date?
    var loading = false
    var commandError: String?
    var busy: String?
    /// The mode last asked for that the TV didn't apply, per kind. Cleared on the next attempt.
    var refused: [STModeKind: STOption] = [:]
    /// SmartThings keeps reporting the last HDMI source after a switch to TV, so an input chosen here
    /// is shown until SmartThings reports a change of its own (anything but what it said at the time).
    private(set) var chosenInput: ChosenInput?
    @ObservationIgnored private var reportedInput: String?

    struct ChosenInput {
        let id: String
        let staleReport: String?
        let at: Date
    }

    @ObservationIgnored private let helper: HomeHelper
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastPollTVOn: Bool?
    @ObservationIgnored var isTVOn: () -> Bool = { true }

    init(helper: HomeHelper, defaults: UserDefaults = .standard) {
        self.helper = helper
        self.defaults = defaults
    }

    var usable: Bool { phase == .ready && (status?.online ?? false) }
    /// Worth trying a command: not known to be broken. Used by scenes before falling back.
    var worthTrying: Bool { if case .unavailable = phase { false } else { true } }
    var unavailableReason: String? { if case .unavailable(let r) = phase { r } else { nil } }

    /// One dim line on SmartThings' state, or nil when all is well.
    var notice: String? {
        switch phase {
        case .idle: return loading ? "Checking SmartThings…" : "SmartThings not checked yet."
        case .unavailable(let reason): return "SmartThings unavailable: \(reason)"
        case .ready:
            if status?.online == false { return "SmartThings sees the TV as offline." }
            if let error = commandError { return "Last change didn't go through: \(error)" }
            return nil
        }
    }

    func input(id: String?) -> STOption? { status?.inputs?.first { $0.matches(id) } }
    var currentInput: STOption? { input(id: chosenInput?.id ?? status?.inputSource) }
    var currentPictureMode: STOption? { status?.pictureModes?.first { $0.matches(status?.pictureMode) } }
    var currentSoundMode: STOption? { status?.soundModes?.first { $0.matches(status?.soundMode) } }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.worthTrying {
                    let on = self.isTVOn()
                    let interval = on ? STConfig.pollWhileOn : STConfig.pollWhileOff
                    let due = self.fetchedAt.map { Date().timeIntervalSince($0) >= interval - 1 } ?? true
                    if due || on != self.lastPollTVOn { await self.fetch() }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func fetch(refresh: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        lastPollTVOn = isTVOn()
        do {
            absorb(try await helper.call("st.status", ["refresh": refresh], timeout: 150, as: STStatus.self))
            fetchedAt = Date()
            phase = .ready
        } catch {
            phase = .unavailable(Self.describe(error))
        }
    }

    func absorb(_ new: STStatus) {
        status = new
        reportedInput = new.inputSource
        if let chosen = chosenInput, let reported = new.inputSource, reported != chosen.staleReport { chosenInput = nil }
    }

    func noteChosenInput(_ id: String, staleReport: String?, at: Date = Date()) {
        chosenInput = ChosenInput(id: id, staleReport: staleReport, at: at)
    }

    /// User-initiated, so it may ask 1Password again.
    func retry() async {
        helper.restartIfStopped()
        _ = try? await helper.call("st.retry", timeout: 10)
        phase = .idle
        commandError = nil
        await fetch(refresh: true)
    }

    func refreshNow() async {
        if worthTrying { await fetch(refresh: true) } else { await retry() }
    }

    @discardableResult
    func setInput(_ id: String) async -> String? {
        let before = reportedInput
        let error = await command("st.set_input", ["id": id], busy: "input:\(id)") { $0.inputSource = id }
        if error == nil { noteChosenInput(id, staleReport: before) }
        return error
    }

    func setPictureMode(_ option: STOption) async { await setMode(.picture, option) }
    func setSoundMode(_ option: STOption) async { await setMode(.sound, option) }

    /// Remote keys that jump straight to a picture mode over the LAN, for inputs where the cloud command is refused.
    static func remoteKey(forPictureMode name: String) -> String? {
        let n = name.lowercased()
        if n.hasPrefix("dynamic") { return "KEY_DYNAMIC" }
        if n.hasPrefix("standard") { return "KEY_STANDARD" }
        if n.hasPrefix("movie") { return "KEY_MOVIE1" }
        if n.hasPrefix("eco") { return "KEY_ESAVING" }
        return nil
    }

    private struct ModeSent: Decodable { let sent: String? }

    /// The mode capabilities take any string and answer COMPLETED even when the TV ignores the value,
    /// so each send is checked against a fresh status read, and the other form (id or name) tried once.
    private func setMode(_ kind: STModeKind, _ option: STOption) async {
        let key = "\(kind.rawValue):\(option.id)"
        let formKey = "st.\(kind.rawValue).form"
        busy = key
        defer { if busy == key { busy = nil } }
        refused[kind] = nil
        var forms = [option.id, option.name].filter { !$0.isEmpty }
        if forms.count == 2, forms[0] == forms[1] { forms.removeLast() }
        if defaults.string(forKey: formKey) == "name" { forms.reverse() }
        var tried: Set<String> = []
        for form in forms where !tried.contains(form) {
            var params: [String: Any] = ["mode": form]
            if let alt = forms.first(where: { $0 != form && !tried.contains($0) }) { params["alt"] = alt }
            let sent: String
            do {
                sent = try await helper.call("st.\(kind.rawValue)", params, timeout: 60, as: ModeSent.self).sent ?? form
            } catch {
                fail(error)
                return
            }
            tried.formUnion([form, sent])
            commandError = nil
            if status != nil {
                if kind == .picture { status!.pictureMode = option.name } else { status!.soundMode = option.name }
            }
            guard let applied = await confirm(kind, option) else { return }
            if applied {
                defaults.set(sent == option.id ? "id" : "name", forKey: formKey)
                return
            }
        }
        refused[kind] = option
    }

    /// nil when the status couldn't be re-read, so nothing is claimed either way.
    private func confirm(_ kind: STModeKind, _ option: STOption) async -> Bool? {
        try? await Task.sleep(for: .seconds(3))
        while loading { try? await Task.sleep(for: .milliseconds(250)) }
        let before = fetchedAt
        await fetch(refresh: true)
        guard fetchedAt != before, phase == .ready else { return nil }
        return option.matches(kind == .picture ? status?.pictureMode : status?.soundMode)
    }

    func powerOn() async {
        _ = try? await helper.call("st.power_on", [:], timeout: 30)
    }

    func launch(_ appID: String) async -> String? {
        await command("st.launch", ["app_id": appID], busy: nil) { _ in }
    }

    /// Returns an error message, or nil on success. Re-reads status a few seconds later to confirm.
    @discardableResult
    private func command(_ method: String, _ params: [String: Any], busy key: String?,
                         optimistic: @escaping (inout STStatus) -> Void) async -> String? {
        if let key { busy = key }
        defer { if key != nil, busy == key { busy = nil } }
        do {
            _ = try await helper.call(method, params, timeout: 60)
            commandError = nil
            if status != nil { optimistic(&status!) }
            Task {
                try? await Task.sleep(for: .seconds(3))
                await fetch()
            }
            return nil
        } catch {
            return fail(error)
        }
    }

    @discardableResult
    private func fail(_ error: Error) -> String {
        let message = Self.describe(error)
        commandError = message
        if case HomeHelper.Failure.remote(_, let code) = error, Self.isAuthFailure(code) {
            phase = .unavailable(message)
        }
        return message
    }

    private static func isAuthFailure(_ code: String?) -> Bool {
        guard let code else { return false }
        return code.hasPrefix("st_") || code.hasPrefix("op_") || code == "reauth_needed" || code == "token_failed"
    }

    private static func describe(_ error: Error) -> String {
        if case HomeHelper.Failure.remote(let message, _) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? "SmartThings didn't answer."
    }
}
