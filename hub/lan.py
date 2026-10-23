"""LAN policy, ported from WebAccess.swift: private, link-local and loopback peers only. CGNAT (100.64/10,
used by tunnels such as Tailscale) and every public address are refused."""
import ipaddress
import socket

_V4_LOCAL = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")]


def is_local(text, allow_loopback=True):
    try:
        ip = ipaddress.ip_address(text.split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    if ip.is_loopback:
        return allow_loopback
    if ip in ipaddress.ip_network("100.64.0.0/10"):
        return True
    if ip.version == 4:
        return any(ip in n for n in _V4_LOCAL)
    return ip in ipaddress.ip_network("fe80::/10") or ip in ipaddress.ip_network("fc00::/7")


def primary_address():
    """The address the default route uses. A UDP connect sends nothing; it only picks the interface."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.168.0.1", 9))
            ip = s.getsockname()[0]
        except OSError:
            return None
    return ip if is_local(ip, allow_loopback=False) else None


def own_addresses():
    found = []
    first = primary_address()
    if first:
        found.append(first)
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in found and is_local(ip, allow_loopback=False):
                found.append(ip)
    except OSError:
        pass
    return found


def host_names():
    name = socket.gethostname().lower().split(".")[0]
    return {name, f"{name}.local", f"{name}.lan", f"{name}.home"}
