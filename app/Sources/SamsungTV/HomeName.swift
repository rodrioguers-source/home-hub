import Foundation
import Observation
import AppKit
import dnssd

/// Announces a host name and an _http._tcp service for it over Bonjour, without root.
@MainActor
protocol NameAdvertiser: AnyObject {
    /// `onLost` runs if mDNSResponder reports a conflict (another device holds the name) or drops the records.
    func publish(host: String, ip: String, interface: UInt32, port: UInt16, ttl: UInt32,
                 onLost: @escaping @MainActor (String) -> Void) -> String?
    /// Deregisters, which makes mDNSResponder send goodbye packets so phones drop the address at once.
    func withdraw()
}

/// The real advertiser: one connection to mDNSResponder holding a unique A record and a service on it.
/// Both go when the connection closes, so they also vanish if the app quits or crashes.
@MainActor
final class DNSSDAdvertiser: NameAdvertiser {
    private final class Box: @unchecked Sendable {
        let onLost: @MainActor (String) -> Void
        init(_ onLost: @escaping @MainActor (String) -> Void) { self.onLost = onLost }
    }

    private var connection: DNSServiceRef?
    private var service: DNSServiceRef?
    private var record: DNSRecordRef?
    private var box: Unmanaged<Box>?
    private let instance: String

    init(instance: String = "Home Hub") { self.instance = instance }

    func publish(host: String, ip: String, interface: UInt32, port: UInt16, ttl: UInt32,
                 onLost: @escaping @MainActor (String) -> Void) -> String? {
        withdraw()
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return "Not an IPv4 address: \(ip)" }
        var conn: DNSServiceRef?
        guard DNSServiceCreateConnection(&conn) == DNSServiceErrorType(kDNSServiceErr_NoError), let conn else {
            return "Couldn't reach mDNSResponder."
        }
        let box = Unmanaged.passRetained(Box(onLost))
        connection = conn
        self.box = box
        DNSServiceSetDispatchQueue(conn, .main)
        let fqdn = host.hasSuffix(".") ? host : host + "."
        var rec: DNSRecordRef?
        let err = withUnsafeBytes(of: &addr) { raw in
            DNSServiceRegisterRecord(conn, &rec, DNSServiceFlags(kDNSServiceFlagsUnique), interface, fqdn,
                                     UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, raw.baseAddress, ttl,
                                     { _, _, _, error, context in
                                         guard error != DNSServiceErrorType(kDNSServiceErr_NoError), let context else { return }
                                         let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                                         MainActor.assumeIsolated { box.onLost(DNSSDAdvertiser.describe(error)) }
                                     }, box.toOpaque())
        }
        guard err == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            withdraw()
            return "Couldn't register \(fqdn): \(Self.describe(err))"
        }
        record = rec
        var svc: DNSServiceRef? = conn
        let flags = DNSServiceFlags(kDNSServiceFlagsShareConnection) | DNSServiceFlags(kDNSServiceFlagsNoAutoRename)
        let serr = DNSServiceRegister(&svc, flags, interface, instance, "_http._tcp", "local.", fqdn, port.bigEndian, 0, nil,
                                      { _, _, error, _, _, _, context in
                                          guard error != DNSServiceErrorType(kDNSServiceErr_NoError), let context else { return }
                                          let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                                          MainActor.assumeIsolated { box.onLost(DNSSDAdvertiser.describe(error)) }
                                      }, box.toOpaque())
        guard serr == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            withdraw()
            return "Couldn't register the Home Hub service: \(Self.describe(serr))"
        }
        service = svc
        return nil
    }

    func withdraw() {
        if let service { DNSServiceRefDeallocate(service) }
        if let connection { DNSServiceRefDeallocate(connection) }
        service = nil
        connection = nil
        record = nil
        box?.release()
        box = nil
    }

    nonisolated static func describe(_ error: DNSServiceErrorType) -> String {
        switch Int(error) {
        case kDNSServiceErr_NameConflict: "another device already answers for that name"
        case kDNSServiceErr_ServiceNotRunning: "mDNSResponder restarted"
        default: "mDNS error \(error)"
        }
    }
}

/// While the hub is offline and this Mac stands in, the Mac answers for homehub.local so the phone's one
/// saved address (http://homehub.local:8787) reaches it. It lets go on the first poll the hub answers.
@MainActor
@Observable
final class HomeName {
    static let shared = HomeName()
    static let host = "homehub.local"
    nonisolated static let ttl: UInt32 = 30
    static let retryAfter: TimeInterval = 30

    private(set) var publishedIP: String?
    private(set) var problem: String?

    @ObservationIgnored var advertiser: NameAdvertiser = DNSSDAdvertiser()
    @ObservationIgnored var wanted: () -> Bool = { false }
    @ObservationIgnored var port: () -> UInt16? = { nil }
    @ObservationIgnored var address: () -> (ip: String, interface: UInt32)? = HomeName.primaryAddress
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    var note: String? {
        if let publishedIP { return "Answering \(Self.host) at \(publishedIP)" }
        return problem
    }

    /// Wires it to the hub link and the phone server.
    func configure(hub: HubLink, port: @escaping () -> UInt16?) {
        wanted = { [weak hub] in
            guard let hub, hub.enabled, hub.offline else { return false }
            return !(hub.host ?? "").lowercased().hasPrefix(HomeName.host)
        }
        self.port = port
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.withdraw("the app is quitting") }
        }
    }

    func update() {
        guard wanted() else {
            withdraw("the home hub is back")
            problem = nil
            retryAt = nil
            return
        }
        guard port() == WebConfig.port else {
            withdraw("the phone server isn't on port \(WebConfig.port)")
            problem = "Not answering \(Self.host): the phone server isn't on port \(WebConfig.port)."
            return
        }
        guard let a = address() else {
            withdraw("this Mac has no LAN address")
            return
        }
        if publishedIP == a.ip { return }
        if let retryAt, now() < retryAt { return }
        if let failure = advertiser.publish(host: Self.host, ip: a.ip, interface: a.interface, port: WebConfig.port, ttl: Self.ttl,
                                            onLost: { [weak self] why in self?.lost(why) }) {
            problem = "Couldn't answer \(Self.host): \(failure)"
            retryAt = now().addingTimeInterval(Self.retryAfter)
            return
        }
        let moved = publishedIP != nil
        publishedIP = a.ip
        problem = nil
        log?(moved ? "\(Self.host) now points at \(a.ip) (this Mac's address changed)" : "answering \(Self.host) at \(a.ip) while the hub is down")
    }

    private func lost(_ why: String) {
        advertiser.withdraw()
        publishedIP = nil
        problem = "Not answering \(Self.host): \(why). Trying again shortly."
        retryAt = now().addingTimeInterval(Self.retryAfter)
        log?("stopped answering \(Self.host): \(why)")
    }

    func withdraw(_ why: String) {
        guard publishedIP != nil else { return }
        advertiser.withdraw()
        publishedIP = nil
        log?("stopped answering \(Self.host): \(why)")
    }

    nonisolated static func primaryAddress() -> (ip: String, interface: UInt32)? {
        guard let first = LANAddress.ownInterfaces().first else { return nil }
        return (first.ip, if_nametoindex(first.name))
    }
}
