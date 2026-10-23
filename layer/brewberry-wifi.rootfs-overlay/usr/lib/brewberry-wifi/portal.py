#!/usr/bin/python3
"""Redirect from port 80 to the device web interface (ADR-0004, OS11).

Started by brewberry-portal.socket as the unprivileged user brewberry-web. It
answers every request with a redirect and nothing else:

- On the setup hotspot every name resolves to the Pi (dnsmasq-shared.d), so
  the captive-portal checks of phones and computers (captive.apple.com,
  connectivitycheck.gstatic.com, www.msftconnecttest.com, ...) land here: a
  request for any other host name goes to the Wi-Fi page at the address it
  arrived on, http://10.42.0.1:8081/#wifi, which makes them open it.
- A request for the Pi's own name or an IP address goes to the same name on
  port 8081. Elsewhere than on the hotspot, connections to port 80 go to the
  app instead (brewberrypi-port80, ADR-0006) and never reach this redirect.
"""

import ipaddress
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Overrides are for tests only (tests/web/test_portal.py).
PORT = int(os.environ.get("BREWBERRY_PORTAL_PORT", "80"))
WEB_PORT = 8081


def own_host(host):
    """The host name of a request for this device (its name or an IP address), or None."""
    if not host:
        return None
    name = host.rsplit(":", 1)[0] if not host.endswith("]") else host
    name = name.strip("[]").lower()
    try:
        ip = ipaddress.ip_address(name)
        return f"[{ip}]" if ip.version == 6 else str(ip)
    except ValueError:
        pass
    own = socket.gethostname().lower()
    return name if name in (own, own + ".local") else None


def local_address(sock):
    """The address a connection arrived on, as a URL host."""
    addr = sock.getsockname()[0]
    ip = ipaddress.ip_address(addr.split("%", 1)[0])
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return f"[{ip}]" if ip.version == 6 else str(ip)


class Handler(BaseHTTPRequestHandler):
    server_version = "brewberry-portal"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass  # every phone on the hotspot asks often; nothing worth keeping

    def _redirect(self):
        host = own_host(self.headers.get("Host", ""))
        if host:
            target = f"http://{host}:{WEB_PORT}/"
        else:
            target = f"http://{local_address(self.connection)}:{WEB_PORT}/#wifi"
        body = (f'<!doctype html><title>BrewberryPi OS</title>'
                f'<a href="{target}">BrewberryPi OS</a>\n').encode()
        self.send_response(302)
        self.send_header("Location", target)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    do_GET = do_HEAD = do_POST = _redirect


def listening_socket():
    """systemd's socket (LISTEN_FDS), or a socket of our own for tests."""
    if os.environ.get("LISTEN_PID") == str(os.getpid()) and int(os.environ.get("LISTEN_FDS", "0")) >= 1:
        return socket.socket(fileno=3)
    sock = socket.create_server(("127.0.0.1", PORT))
    return sock


def main():
    sock = listening_socket()

    class Server(ThreadingHTTPServer):
        address_family = sock.family
        daemon_threads = True

    server = Server(sock.getsockname()[:2], Handler, bind_and_activate=False)
    server.socket.close()
    server.socket = sock
    print("brewberry-portal: redirecting to port 8081", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
