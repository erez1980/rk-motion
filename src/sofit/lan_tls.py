"""A certificate so a phone gets a secure connection to this computer.

Browsers only hand a page its useful powers over a secure connection: the
share sheet that can drop a finished movie straight into the camera roll, and
notifications. On this machine ``http://127.0.0.1`` already counts as secure;
a phone reaching the computer by its network address does not. So LAN mode
serves HTTPS with a certificate generated here and kept in ``~/.rk-motion``.

No authority signs it, so each phone shows a warning once and its owner has to
accept it. That is the price of saving to the camera roll over Wi-Fi — and it
is not a stand-in for a real certificate on a public host: this one exists
only to secure the hop between a phone and this computer on a home network.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
import time
from pathlib import Path

CERT_DIR = Path.home() / ".rk-motion"
CERT = CERT_DIR / "lan-cert.pem"
KEY = CERT_DIR / "lan-key.pem"
STAMP = CERT_DIR / "lan-cert.json"
# Apple refuses server certificates valid for longer than 398 days, so a
# generous expiry would be rejected outright rather than merely warned about.
VALID_DAYS = 397
SUBJECT = "RK Motion (this computer)"


def certificate_for(ip: str) -> tuple[Path, Path] | None:
    """Certificate and key covering ``ip``, made on first use and reused after.

    Reusing the same file matters: a phone that accepted the certificate once
    should not be asked again the next time the app starts. Returns ``None``
    when this machine has no way to make one, so the caller can fall back to
    plain http rather than fail to start.
    """
    if _current(ip):
        return CERT, KEY
    CERT_DIR.mkdir(parents=True, exist_ok=True)
    # openssl first: it is on every Mac and Linux box, and trying a broken
    # cryptography install first would spray its panic across the terminal.
    if _write_with_openssl(ip) or _write_with_cryptography(ip):
        for path in (CERT, KEY):
            path.chmod(0o600)
        STAMP.write_text(json.dumps({"ip": ip, "created": time.time()}), encoding="utf-8")
        return CERT, KEY
    return None


def _current(ip: str) -> bool:
    """True when the stored certificate still covers this address and date."""
    if not (CERT.is_file() and KEY.is_file() and STAMP.is_file()):
        return False
    try:
        stamp = json.loads(STAMP.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    age_days = (time.time() - float(stamp.get("created", 0))) / 86400
    return stamp.get("ip") == ip and 0 <= age_days < VALID_DAYS - 1


def _write_with_cryptography(ip: str) -> bool:
    # Guarded down to BaseException on purpose: a half-installed cryptography
    # panics out of its Rust bindings with an exception that does not derive
    # from Exception at all. No certificate is worth taking the app down for
    # when openssl is right there — but a real interrupt still gets through.
    try:
        import datetime
        import ipaddress

        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException:
        return False

    try:
        return _build_with_cryptography(ip, x509, hashes, serialization, rsa, NameOID,
                                        datetime, ipaddress)
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException:
        return False


def _build_with_cryptography(ip, x509, hashes, serialization, rsa, NameOID,
                             datetime, ipaddress) -> bool:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, SUBJECT)])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name).issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(hours=1))   # tolerate clock skew
        .not_valid_after(now + datetime.timedelta(days=VALID_DAYS))
        .add_extension(x509.SubjectAlternativeName(_alt_names(ip, x509, ipaddress)), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    KEY.write_bytes(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption()))
    CERT.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return True


def _alt_names(ip: str, x509, ipaddress) -> list:
    """Every address a browser might use to reach this computer."""
    names = [x509.DNSName("localhost")]
    for address in (ip, "127.0.0.1"):
        try:
            names.append(x509.IPAddress(ipaddress.ip_address(address)))
        except ValueError:
            continue
    return names


_OPENSSL_CONFIG = """
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = {subject}
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = localhost
IP.1 = {ip}
IP.2 = 127.0.0.1
"""


def _write_with_openssl(ip: str) -> bool:
    """Fallback for machines without the cryptography package.

    A config file rather than -addext, because that flag is missing from the
    LibreSSL build macOS ships.
    """
    with tempfile.NamedTemporaryFile("w", suffix=".cnf", delete=False) as handle:
        handle.write(_OPENSSL_CONFIG.format(subject=SUBJECT, ip=ip))
        config = handle.name
    try:
        result = subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
             "-days", str(VALID_DAYS), "-nodes", "-config", config,
             "-keyout", str(KEY), "-out", str(CERT)],
            capture_output=True)
        return result.returncode == 0 and CERT.is_file() and KEY.is_file()
    except OSError:
        return False
    finally:
        Path(config).unlink(missing_ok=True)
