import Foundation
import AppKit

enum HelperConfig {
    static let base = "/Users/rodrigocarneiro/personal/samsung-tv"
    static let python = "\(base)/.venv/bin/python"
    static let script = "\(base)/helper/home_helper.py"
}

/// Splits the helper's stdout into lines off the main thread.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data.subdata(in: data.startIndex..<nl))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
}

/// What the lights need from the helper; the presets dry-run swaps in fake bulbs.
@MainActor
protocol LightsTransport: AnyObject {
    func call(_ method: String, _ params: [String: Any], timeout: Double) async throws -> Data
    func restartIfStopped()
}

extension LightsTransport {
    func request<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type) async throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: try await call(method, params, timeout: 45))
    }
}

extension HomeHelper: LightsTransport {}

/// Owns the long-lived Python helper (lights + PSN) and speaks JSON lines with it.
/// Restarts it with backoff if it dies; each restart re-reads 1Password, so restarts are capped.
@MainActor
final class HomeHelper {
    enum Failure: Error, LocalizedError {
        case notRunning, timeout, remote(String, code: String?)

        var errorDescription: String? {
            switch self {
            case .notRunning: "The home helper isn't running."
            case .timeout: "The home helper didn't answer in time."
            case .remote(let message, _): message
            }
        }
    }

    private let live: Bool
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var restarts = 0
    private var restartScheduled = false
    private var stopping = false
    private(set) var stopped = false
    /// Set only by the app. With "Use home hub" on, SmartThings calls go to the hub only when this Mac has no
    /// token chain of its own it may refresh (no "SmartThings OAuth Mac" item); see `ownsChain`.
    var hub: HubLink?
    /// Whether the Mac's SmartThings item is one it refreshes itself. Nil until checked.
    private(set) var ownsChain: Bool?
    private var chainCheckedAt: Date?

    init(live: Bool = true) {
        self.live = live
        guard live else { return }
        signal(SIGPIPE, SIG_IGN)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminate() }
        }
        start()
    }

    func start() {
        guard live, process == nil else { return }
        stopped = false
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HelperConfig.python)
        process.arguments = ["-u", HelperConfig.script]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for line in buffer.append(chunk) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(line) } }
            }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(proc) } }
        }
        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
        } catch {
            stopped = true
        }
    }

    /// User-initiated: resets the restart budget.
    func restartIfStopped() {
        guard live, process == nil else { return }
        restarts = 0
        start()
    }

    func terminate() {
        stopping = true
        process?.terminate()
    }

    /// Asks the local helper once (again every 5 min while the answer is no) which item it uses.
    private func checkOwnChain() async -> Bool {
        if ownsChain == true { return true }
        if let at = chainCheckedAt, Date().timeIntervalSince(at) < 300 { return false }
        chainCheckedAt = Date()
        struct Chain: Decodable { let item: String; let mayRefresh: Bool }
        let chain = try? await call("st.chain", [:], timeout: 60, as: Chain.self)
        ownsChain = chain?.mayRefresh == true
        return ownsChain == true
    }

    /// Returns the JSON-encoded `result` of the call.
    func call(_ method: String, _ params: [String: Any] = [:], timeout: Double = 45) async throws -> Data {
        guard live else { throw Failure.notRunning }
        if let hub, hub.routes(method), await !checkOwnChain() { return try await hub.rpc(method, params, timeout: timeout) }
        if process == nil { start() }
        guard let input else { throw Failure.notRunning }
        let id = nextID
        nextID += 1
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) else {
            throw Failure.remote("Couldn't encode request", code: nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: body + Data([0x0A]))
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: Failure.notRunning)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timeout)
            }
        }
    }

    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], timeout: Double = 45, as type: T.Type) async throws -> T {
        let data = try await call(method, params, timeout: timeout)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func receive(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = json["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if json["ok"] as? Bool == true {
            let result = json["result"] ?? NSNull()
            let data = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            continuation.resume(returning: data)
        } else {
            continuation.resume(throwing: Failure.remote(json["error"] as? String ?? "Unknown error", code: json["code"] as? String))
        }
    }

    private func exited(_ proc: Process) {
        guard proc === process else { return }
        process = nil
        input = nil
        for (_, continuation) in pending { continuation.resume(throwing: Failure.notRunning) }
        pending.removeAll()
        guard !stopping else { return }
        guard restarts < 5 else { stopped = true; return }
        guard !restartScheduled else { return }
        restartScheduled = true
        let delay = min(pow(2, Double(restarts)) * 2, 60)
        restarts += 1
        Task {
            try? await Task.sleep(for: .seconds(delay))
            restartScheduled = false
            start()
        }
    }
}
