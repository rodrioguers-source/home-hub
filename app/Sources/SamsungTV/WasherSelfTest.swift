import Foundation

/// Scripted st.washer answers. Touches no network.
@MainActor
final class FakeWasherSource: WasherSource {
    var next: Result<WasherStatus, Error> = .success(WasherStatus(found: false))
    private(set) var fetches = 0

    func fetch() async throws -> WasherStatus {
        fetches += 1
        return try next.get()
    }
}

@MainActor
final class FakeWasherAlerts: WasherAlerts {
    private(set) var prepared = 0
    private(set) var posted: [String] = []

    func prepare() { prepared += 1 }
    func post(_ title: String, _ body: String) { posted.append("\(title): \(body)") }
}

extension WasherStatus {
    static func sample(_ state: String, phase: String? = "rinse", progress: Int? = 71, remaining: Int? = 20,
                       completion: String? = "2026-10-16T12:21:31Z", since: String = "2026-10-16T11:17:58.084Z",
                       job: String? = nil) -> WasherStatus {
        WasherStatus(label: "Washing machine", state: state, stateSince: since, phase: phase, jobState: job ?? phase,
                     progress: progress, remainingMin: remaining, operationMin: 66, completionTime: completion,
                     phases: [.init(name: "wash", minutes: 28), .init(name: "rinse", minutes: 23), .init(name: "spin", minutes: 13)],
                     temp: "40", spin: "1400", rinses: "2", kidsLock: false, updatedAt: "2026-10-16T12:01:31.309Z")
    }

    static func done(_ since: String) -> WasherStatus {
        // As seen live after a real cycle: progress, time left and completion reset to junk values.
        .sample("ready", phase: "none", progress: 1, remaining: 163, completion: "2026-10-16T15:07:39Z", since: since, job: "none")
    }
}

/// `SamsungTV --washer-dryrun`: runs the shared washer's chip, claims, polling and notifications against
/// `FakeWasherSource`, and exits non-zero on any failure.
enum WasherSelfTest {
    @MainActor static func runIfRequested() {
        guard CommandLine.arguments.contains("--washer-dryrun") else { return }
        var done = false
        var failures = 0
        Task { @MainActor in
            failures = await run()
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func run() async -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        let suite = "com.rodrigocarneiro.samsungtv.washer-dryrun"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let t0 = WasherText.date("2026-10-16T12:01:31Z")!
        func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
        func make(fresh: Bool = true) -> (WasherModel, FakeWasherSource, FakeWasherAlerts) {
            if fresh { defaults.removePersistentDomain(forName: suite) }
            let source = FakeWasherSource(), alerts = FakeWasherAlerts()
            return (WasherModel(source: source, alerts: alerts, defaults: defaults), source, alerts)
        }
        func bar(_ m: WasherModel, _ now: Date) -> String {
            let d = m.display(now: now)
            return d == .hidden ? "(no bar)" : "\(WasherText.title(d)) | \(WasherText.trailing(d))"
        }
        func chip(_ m: WasherModel, _ now: Date) -> String {
            m.availability(now: now).map { WasherText.chip($0).sentence } ?? "(no chip)"
        }

        print("== Helper JSON")
        let live = """
        {"found": true, "label": "Washing machine", "state": "running", "state_since": "2026-10-16T11:17:58.084Z", "phase": "rinse",
         "job_state": "rinse", "progress": 71, "remaining_min": 20, "operation_min": 66, "completion_time": "2026-10-16T12:21:31Z",
         "phases": [{"name": "wash", "minutes": 28}, {"name": "rinse", "minutes": 23}, {"name": "spin", "minutes": 13}],
         "temp": "40", "spin": "1400", "rinses": "2", "kids_lock": false, "updated_at": "2026-10-16T12:01:31.309Z"}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        check((try? decoder.decode(WasherStatus.self, from: Data(live.utf8))) == .sample("running"), "Decodes the helper's st.washer answer (snake_case keys)")
        check((try? decoder.decode(WasherStatus.self, from: Data(#"{"found": false}"#.utf8)))?.found == false, "Decodes a missing washer")
        check(WasherClaim(start: WasherStatus.sample("running").estimatedStart(now: t0)).start == WasherText.date("2026-10-16T11:15:31Z"),
              "Cycle start = completion time − operation time (11:15:31Z)")

        print("\n== Free")
        var (m, source, alerts) = make()
        source.next = .success(.done("2026-10-14T09:00:00Z"))
        await m.tick(now: t0)
        check(chip(m, t0) == "Washer free" && bar(m, t0) == "(no bar)", "Chip: \(chip(m, t0)), no bar")
        check(m.interval == WasherConfig.pollIdle && alerts.prepared == 0, "Every 5 min, no permission prompt")
        m.setNotifyWhenFree(true)
        check(!m.notifyWhenFree && alerts.prepared == 0, "\"Tell me when it's free\" does nothing while it's already free")

        print("\n== Busy, someone else's")
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        check(chip(m, t0) == "Washer busy · 20 min left · done 13:21" && bar(m, t0) == "(no bar)", "Chip: \(chip(m, t0)), no bar")
        check(WasherText.chip(m.availability(now: t0)!).short == "20m", "Chip short form: 20m")
        check(WasherText.chip(.busy(remaining: 75, done: nil)).short == "1h15" && WasherText.chip(.busy(remaining: 0, done: nil)).short == "Busy",
              "Long and zero remaining fit the chip")
        check(chip(m, at(5)) == "Washer busy · 15 min left · done 13:21", "Counts down between polls")
        check(m.claim == nil && alerts.prepared == 0, "Never auto-claimed, no permission prompt")
        check(m.interval == WasherConfig.pollActive, "Polls every 60 s while busy")
        await m.tick(now: at(0.5))
        check(source.fetches == 2, "Not polled again after 30 s")
        source.next = .success(.sample("paused"))
        await m.tick(now: at(1))
        check(source.fetches == 3 && chip(m, at(1)) == "Washer paused · 20 min left", "Paused chip: \(chip(m, at(1)))")
        source.next = .success(.done("2026-10-16T12:21:40Z"))
        await m.fetch(now: at(21))
        check(chip(m, at(21)) == "Washer free" && bar(m, at(21)) == "(no bar)" && alerts.posted.isEmpty,
              "Someone else's cycle ends: chip says free, no bar, no notification")

        print("\n== Tell me when it's free")
        (m, source, alerts) = make()
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        m.setNotifyWhenFree(true)
        check(m.notifyWhenFree && alerts.prepared == 1, "Turned on; asks for notification permission now")
        check(make(fresh: false).0.notifyWhenFree, "Survives a relaunch")
        await m.fetch(now: at(1))
        check(alerts.posted.isEmpty, "Nothing while it's still running")
        source.next = .success(.done("2026-10-16T12:21:40Z"))
        await m.fetch(now: at(21))
        check(alerts.posted == ["The washer is free: Finished at 13:21"], "One notification: \(alerts.posted)")
        check(!m.notifyWhenFree, "Switches itself off")
        source.next = .success(.sample("running", completion: "2026-10-16T13:40:00Z", since: "2026-10-16T12:30:00Z"))
        await m.fetch(now: at(30))
        source.next = .success(.done("2026-10-16T13:40:10Z"))
        await m.fetch(now: at(100))
        check(alerts.posted.count == 1, "Not told again about the next cycle")

        print("\n== Claimed, running")
        (m, source, alerts) = make()
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        m.setNotifyWhenFree(true)
        m.claimCurrent(now: t0)
        check(m.claim != nil && !m.notifyWhenFree && alerts.prepared >= 1, "Claimed; the free alert is folded into it; permission asked")
        check(bar(m, t0) == "Rinsing | 20 min left · done 13:21" && chip(m, t0) == "(no chip)", "Bar: \(bar(m, t0)), chip hidden")
        let segs = WasherProgress.fills(m.status?.phases ?? [], progress: 71, current: "rinse")
        check(segs.count == 3 && segs[0].fill == 1 && segs[2].fill == 0 && (0.6...0.9).contains(segs[1].fill),
              "Phase segments: wash full, rinse \(Int((segs.count > 1 ? segs[1].fill : 0) * 100))%, spin empty")
        check(WasherProgress.fills([], progress: 40, current: nil) == [.init(weight: 1, fill: 0.4)], "No phases: one plain bar")
        check(WasherProgress.fills(m.status?.phases ?? [], progress: 79, current: "spin")[2].fill > 0, "Current phase always shows as started")
        check(WasherText.detail(m.status!, fetchedAt: nil) == "Washing machine · 40 °C · 1400 rpm · 2 rinses · 71%", "Tooltip detail")
        source.next = .success(.sample("running", completion: "2026-10-16T12:24:00Z"))
        await m.fetch(now: at(1))
        check(m.claim != nil && bar(m, at(1)).hasSuffix("done 13:24"), "Completion time drifting by minutes keeps the claim")
        source.next = .success(.sample("paused", completion: "2026-10-16T13:10:00Z"))
        await m.fetch(now: at(2))
        check(m.claim != nil && bar(m, at(2)) == "Paused · Rinsing | 20 min left", "Long pause seen live keeps the claim: \(bar(m, at(2)))")
        source.next = .success(.sample("running"))
        await m.fetch(now: at(3))
        let (relaunched, rSource, _) = make(fresh: false)
        rSource.next = .success(.sample("running"))
        await relaunched.fetch(now: at(4))
        check(relaunched.claim != nil && bar(relaunched, at(4)).hasPrefix("Rinsing"), "Relaunch mid-cycle keeps the claim")

        print("\n== Claimed, finished")
        source.next = .success(.done("2026-10-16T12:21:40Z"))
        await m.fetch(now: at(21))
        check(alerts.posted == ["Your washing is done: Finished at 13:21"], "One notification: \(alerts.posted)")
        check(bar(m, at(21)) == "Your washing is done | Finished at 13:21" && chip(m, at(21)) == "(no chip)", "Bar: \(bar(m, at(21)))")
        await m.fetch(now: at(26))
        check(alerts.posted.count == 1 && m.interval == WasherConfig.pollIdle, "No repeat; back to every 5 min")
        let (later, lSource, lAlerts) = make(fresh: false)
        lSource.next = .success(.done("2026-10-16T12:21:40Z"))
        await later.fetch(now: at(27))
        check(lAlerts.posted.isEmpty && bar(later, at(27)).hasPrefix("Your washing"), "Relaunch after the notification: bar kept, not notified again")
        check(bar(m, at(50)) != "(no bar)" && bar(m, at(52)) == "(no bar)" && chip(m, at(52)) == "Washer free",
              "Bar for 30 min after it ends, then back to the chip")
        await m.fetch(now: at(52))
        check(m.claim == nil && make(fresh: false).0.claim == nil, "Claim cleared and forgotten")

        print("\n== Cycle changes clear a claim")
        (m, source, alerts) = make()
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        m.claimCurrent(now: t0)
        source.next = .success(.done("2026-10-16T12:21:40Z"))
        await m.fetch(now: at(21))
        source.next = .success(.sample("running", completion: "2026-10-16T13:30:00Z", since: "2026-10-16T12:24:00Z"))
        await m.fetch(now: at(23))
        check(m.claim == nil && bar(m, at(23)) == "(no bar)" && chip(m, at(23)).hasPrefix("Washer busy"),
              "Someone starts a wash after mine: claim cleared at once, chip says busy")
        source.next = .success(.done("2026-10-16T13:30:10Z"))
        await m.fetch(now: at(90))
        check(alerts.posted == ["Your washing is done: Finished at 13:21"], "Their finish isn't announced as mine")

        (m, source, alerts) = make()
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        m.claimCurrent(now: t0)
        let (next, nSource, nAlerts) = make(fresh: false)
        nSource.next = .success(.sample("running", completion: "2026-10-16T15:00:00Z", since: "2026-10-16T13:54:00Z"))
        await next.fetch(now: at(120))
        check(next.claim == nil && nAlerts.posted.isEmpty, "Relaunch into a different cycle (start 2 h later): claim cleared, no notification")

        (m, source, alerts) = make()
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        m.claimCurrent(now: t0)
        let (away, aSource, aAlerts) = make(fresh: false)
        aSource.next = .success(.done("2026-10-16T12:21:40Z"))
        await away.fetch(now: at(70))
        check(away.claim == nil && aAlerts.posted.isEmpty, "Finished over 30 min before the app looked: cleared, no stale notification")

        (m, source, alerts) = make()
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        m.claimCurrent(now: t0)
        m.unclaim()
        check(m.claim == nil && bar(m, t0) == "(no bar)" && chip(m, t0).hasPrefix("Washer busy"), "Not mine: back to the chip")
        source.next = .success(.done("2026-10-16T12:21:40Z"))
        await m.fetch(now: at(21))
        check(alerts.posted.isEmpty, "No notification after Not mine")
        let winter = WasherModel(source: FakeWasherSource(), alerts: FakeWasherAlerts(), defaults: defaults)
        winter.status = .sample("running", completion: "2026-12-01T12:21:00Z")
        check(chip(winter, WasherText.date("2026-12-01T12:00:00Z")!) == "Washer busy · 21 min left · done 12:21", "UK time in winter (GMT)")

        print("\n== Missing and errors")
        (m, source, alerts) = make()
        source.next = .success(WasherStatus(found: false))
        await m.fetch(now: t0)
        check(chip(m, t0) == "(no chip)" && m.phase == .missing && m.interval == WasherConfig.pollMissing,
              "No washer in SmartThings: nothing shown, checked every 30 min")
        source.next = .success(.sample("running"))
        await m.fetch(now: t0)
        source.next = .failure(HomeHelper.Failure.remote("Couldn't reach SmartThings (URLError)", code: "network"))
        await m.fetch(now: at(1))
        check(m.interval == 120 && chip(m, at(1)).hasPrefix("Washer busy"), "Network error: backs off to 2 min, keeps the last state")
        for i in 2...6 { await m.fetch(now: at(Double(i))) }
        check(m.interval == WasherConfig.maxBackoff, "Backoff caps at 15 min")
        source.next = .success(.sample("running"))
        await m.fetch(now: at(20))
        check(m.interval == WasherConfig.pollActive && m.phase == .ready, "Recovers to 60 s after a good read")
        var stOK: Date?
        m.smartThingsOK = { stOK }
        source.next = .failure(HomeHelper.Failure.remote("Couldn't read 'SmartThings OAuth' from 1Password.", code: "st_failed"))
        await m.fetch(now: at(30))
        let before = source.fetches
        await m.tick(now: at(120))
        check(source.fetches == before && m.phase == .unavailable("Couldn't read 'SmartThings OAuth' from 1Password."),
              "Auth failure: stops polling (no repeated Touch ID)")
        stOK = at(10)
        await m.tick(now: at(130))
        check(source.fetches == before, "An older SmartThings success doesn't unblock it")
        stOK = at(140)
        source.next = .success(.sample("running"))
        await m.tick(now: at(141))
        check(source.fetches == before + 1 && m.phase == .ready, "Resumes once SmartThings works again (after a retry)")
        (m, source, alerts) = make()
        source.next = .failure(HomeHelper.Failure.timeout)
        await m.fetch(now: t0)
        check(chip(m, t0) == "(no chip)" && m.interval == 120, "Helper timeout before any data: nothing shown, backs off")
        return failures
    }
}
