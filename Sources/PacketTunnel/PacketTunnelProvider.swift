import NetworkExtension
import Darwin
import os.log

/// The Packet Tunnel Provider: the process the OS runs to carry VPN traffic.
///
/// It bridges iOS's `NEPacketTunnelProvider` to the Rust core (libezvpn.a):
/// configure the tunnel interface from the server's handshake, hand the `utun`
/// fd to Rust, and let Rust run the iroh/QUIC datagram loop.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.example.ezvpn.PacketTunnel", category: "tunnel")
    private var handle: OpaquePointer?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        ezvpn_init_logging()

        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let conf = proto.providerConfiguration
        else {
            completionHandler(Self.error("missing providerConfiguration"))
            return
        }

        let serverNodeID = conf["server_node_id"] as? String ?? ""
        let alpnToken = conf["alpn_token"] as? String ?? ""
        let authToken = conf["auth_token"] as? String
        let relayURLs = conf["relay_urls"] as? [String] ?? []
        let routes = conf["routes"] as? [String] ?? []

        // Build the FFI config JSON.
        let configDict: [String: Any] = [
            "server_node_id": serverNodeID,
            "alpn_token": alpnToken,
            "auth_token": (authToken?.isEmpty == false) ? authToken! : NSNull(),
            "relay_urls": relayURLs,
            "relay_only": false,
        ]
        guard
            let configData = try? JSONSerialization.data(withJSONObject: configDict),
            let configStr = String(data: configData, encoding: .utf8)
        else {
            completionHandler(Self.error("failed to encode config JSON"))
            return
        }

        // ezvpn_connect: connect + handshake. Result/error JSON lands in `buf`.
        var buf = [CChar](repeating: 0, count: 4096)
        let handle = configStr.withCString { cstr in
            ezvpn_connect(cstr, &buf, buf.count)
        }
        let resultStr = String(cString: buf)

        guard let handle else {
            os_log("ezvpn_connect failed: %{public}@", log: log, type: .error, resultStr)
            completionHandler(Self.error("connect failed: \(resultStr)"))
            return
        }
        self.handle = handle
        os_log("handshake result: %{public}@", log: log, type: .info, resultStr)

        guard
            let data = resultStr.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ip = obj["assigned_ip"] as? String,
            let mask = obj["netmask"] as? String,
            let gateway = obj["gateway"] as? String,
            let mtu = obj["mtu"] as? Int
        else {
            ezvpn_stop(handle)
            self.handle = nil
            completionHandler(Self.error("bad network config: \(resultStr)"))
            return
        }

        // Configure the tunnel interface. Split tunnel: only the configured
        // private prefixes are routed through us; everything else stays off.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: gateway)
        let ipv4 = NEIPv4Settings(addresses: [ip], subnetMasks: [mask])
        let included = routes.compactMap { Self.ipv4Route($0) }
        ipv4.includedRoutes = included.isEmpty ? [NEIPv4Route.default()] : included
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: mtu)

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                os_log("setTunnelNetworkSettings failed: %{public}@",
                       log: self.log, type: .error, error.localizedDescription)
                ezvpn_stop(handle)
                self.handle = nil
                completionHandler(error)
                return
            }

            guard let fd = self.tunnelFileDescriptor else {
                ezvpn_stop(handle)
                self.handle = nil
                completionHandler(Self.error("could not locate utun fd"))
                return
            }

            let rc = ezvpn_run(handle, fd)
            if rc != 0 {
                ezvpn_stop(handle)
                self.handle = nil
                completionHandler(Self.error("ezvpn_run failed (rc=\(rc))"))
                return
            }
            os_log("tunnel running on fd %d", log: self.log, type: .info, fd)
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel: %d", log: log, type: .info, reason.rawValue)
        if let handle {
            ezvpn_stop(handle)
            self.handle = nil
        }
        completionHandler()
    }

    // MARK: - Helpers

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.example.ezvpn", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Convert "10.0.0.0/8" into an NEIPv4Route.
    private static func ipv4Route(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return nil
        }
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: ipv4Mask(prefix))
    }

    private static func ipv4Mask(_ prefix: Int) -> String {
        let m: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
        return "\((m >> 24) & 0xff).\((m >> 16) & 0xff).\((m >> 8) & 0xff).\(m & 0xff)"
    }

    /// Locate the `utun` file descriptor the OS created for this tunnel.
    ///
    /// NetworkExtension does not hand the fd to us directly. The iOS SDK omits
    /// `<sys/kern_control.h>`, so we use the portable technique: probe each open
    /// fd with the `UTUN_OPT_IFNAME` control-socket option and keep the one
    /// whose interface name starts with `utun`. The constants are hardcoded
    /// because their headers are unavailable on iOS:
    ///   SYSPROTO_CONTROL = 2 (sys/sys_domain.h),
    ///   UTUN_OPT_IFNAME  = 2 (net/if_utun.h).
    private var tunnelFileDescriptor: Int32? {
        let sysprotoControl: Int32 = 2
        let utunOptIfname: Int32 = 2
        var nameBuf = [CChar](repeating: 0, count: 64)
        for fd: Int32 in 0...1024 {
            var len = socklen_t(nameBuf.count)
            let ret = getsockopt(fd, sysprotoControl, utunOptIfname, &nameBuf, &len)
            if ret == 0, String(cString: nameBuf).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }
}
