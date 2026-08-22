"""The certificate that lets a phone reach this computer securely.

A browser only opens the share sheet that can save a movie to the camera roll
over a secure connection, and a phone reaching this machine by its network
address does not get one for free. These cover making that certificate, and
the ways it is allowed to fail.
"""
import json
import shutil
import ssl
import subprocess
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from sofit import lan_tls


@pytest.fixture(autouse=True)
def cert_home(tmp_path, monkeypatch):
    monkeypatch.setattr(lan_tls, "CERT_DIR", tmp_path / ".rk-motion")
    monkeypatch.setattr(lan_tls, "CERT", tmp_path / ".rk-motion" / "lan-cert.pem")
    monkeypatch.setattr(lan_tls, "KEY", tmp_path / ".rk-motion" / "lan-key.pem")
    monkeypatch.setattr(lan_tls, "STAMP", tmp_path / ".rk-motion" / "lan-cert.json")


needs_openssl = pytest.mark.skipif(shutil.which("openssl") is None, reason="needs openssl")


@needs_openssl
def test_the_certificate_covers_every_address_a_phone_might_use():
    """Safari rejects a certificate outright if the address it dialled is not
    named in it, before the user ever sees the accept-once prompt."""
    pair = lan_tls.certificate_for("192.168.1.42")
    assert pair, "openssl is here, so a certificate should have been made"

    described = subprocess.run(
        ["openssl", "x509", "-in", str(lan_tls.CERT), "-noout", "-ext", "subjectAltName"],
        capture_output=True, text=True, check=True).stdout
    assert "IP Address:192.168.1.42" in described
    assert "IP Address:127.0.0.1" in described and "DNS:localhost" in described


@needs_openssl
def test_the_certificate_is_short_lived_enough_for_apple_to_accept_it():
    lan_tls.certificate_for("192.168.1.42")
    assert lan_tls.VALID_DAYS < 398, "Apple refuses server certificates valid longer"


@needs_openssl
def test_the_same_phone_is_not_asked_to_accept_it_twice():
    """Regenerating on every launch would re-prompt on every phone, every time."""
    lan_tls.certificate_for("192.168.1.42")
    first = lan_tls.CERT.read_bytes()

    assert lan_tls.certificate_for("192.168.1.42")
    assert lan_tls.CERT.read_bytes() == first

    # ...but a new network address is a different machine identity.
    assert lan_tls.certificate_for("10.0.0.9")
    assert lan_tls.CERT.read_bytes() != first


@needs_openssl
def test_an_expired_or_corrupt_record_just_makes_a_new_certificate():
    lan_tls.certificate_for("192.168.1.42")
    lan_tls.STAMP.write_text("not json", encoding="utf-8")
    assert lan_tls.certificate_for("192.168.1.42")

    lan_tls.STAMP.write_text(json.dumps({"ip": "192.168.1.42", "created": 0}), encoding="utf-8")
    stale = lan_tls.CERT.read_bytes()
    assert lan_tls.certificate_for("192.168.1.42")
    assert lan_tls.CERT.read_bytes() != stale, "an ancient certificate has to be replaced"


def test_no_way_to_make_one_is_reported_not_raised(monkeypatch):
    """The app has to keep starting on localhost; only phone access is lost."""
    monkeypatch.setattr(lan_tls, "_write_with_openssl", lambda ip: False)
    monkeypatch.setattr(lan_tls, "_write_with_cryptography", lambda ip: False)
    assert lan_tls.certificate_for("192.168.1.42") is None


def test_a_broken_cryptography_install_does_not_take_the_app_down(monkeypatch):
    """Its Rust bindings panic with something that is not even an Exception."""
    class Panic(BaseException):
        pass

    def explode(*args, **kwargs):
        raise Panic("Python API call failed")

    monkeypatch.setattr(lan_tls, "_build_with_cryptography", explode)
    assert lan_tls._write_with_cryptography("192.168.1.42") is False


@needs_openssl
def test_a_phone_can_actually_talk_to_the_server_over_it(tmp_path):
    """End to end: wrap a listener the way LAN mode does and make a request."""
    class Hello(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"secure")

        def log_message(self, *args):
            pass

    pair = lan_tls.certificate_for("127.0.0.1")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(*pair)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Hello)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        client = ssl.create_default_context()
        client.check_hostname = False
        client.verify_mode = ssl.CERT_NONE      # a phone accepts it by hand instead
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=client), urllib.request.ProxyHandler({}))
        with opener.open(f"https://127.0.0.1:{server.server_port}/", timeout=10) as response:
            assert response.status == 200
            assert response.read() == b"secure"
    finally:
        server.shutdown()
        server.server_close()
