"""Loopback-only disposable FTP/SFTP servers. Never uses personal accounts."""
import json
import os
import socket
import sys
import threading
import time
import datetime
import ipaddress
from pathlib import Path

import paramiko
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
(root / "Grüsse mit Leerzeichen.txt").write_text("OpenCommander FTP/SFTP fixture\n", encoding="utf-8")
(root / "Ordner").mkdir(exist_ok=True)
(root / "Ordner" / "Kind.txt").write_text("nested\n", encoding="utf-8")
host_key = paramiko.RSAKey.generate(2048)
wrong_host_key = paramiko.RSAKey.generate(2048)
client_key = paramiko.RSAKey.generate(2048)
key_path = root.parent / "client-key"
client_key.write_private_key_file(str(key_path))
os.chmod(key_path, 0o600)

authorizer = DummyAuthorizer()
authorizer.add_user("fixture", "test-only-password", str(root), perm="elradfmwMT")
authorizer.add_anonymous(str(root), perm="elr")
FTPHandler.authorizer = authorizer
ftp = FTPServer(("127.0.0.1", 0), FTPHandler)
ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "OpenCommander disposable QA CA")])
now = datetime.datetime.now(datetime.timezone.utc)
ca = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(ca_key.public_key())
      .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
      .not_valid_after(now + datetime.timedelta(days=1)).add_extension(x509.BasicConstraints(ca=True, path_length=None), True)
      .sign(ca_key, hashes.SHA256()))
server_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
cert = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")]))
        .issuer_name(name).public_key(server_key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False)
        .sign(ca_key, hashes.SHA256()))
ca_path = root.parent / "qa-ca.pem"
cert_path = root.parent / "qa-server.pem"
ca_path.write_bytes(ca.public_bytes(serialization.Encoding.PEM))
cert_path.write_bytes(server_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                              serialization.NoEncryption()) + cert.public_bytes(serialization.Encoding.PEM))
os.chmod(cert_path, 0o600)
TLS_FTPHandler.authorizer = authorizer
TLS_FTPHandler.certfile = str(cert_path)
TLS_FTPHandler.tls_control_required = True
TLS_FTPHandler.tls_data_required = True
ftps = FTPServer(("127.0.0.1", 0), TLS_FTPHandler)
stopped = threading.Event()
def serve_ftp():
    try:
        ftp.serve_forever(timeout=0.1, handle_exit=False)
    except Exception:
        if not stopped.is_set():
            raise
ftp_thread = threading.Thread(target=serve_ftp, daemon=True)
ftp_thread.start()

class Auth(paramiko.ServerInterface):
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == "fixture" and key == client_key else paramiko.AUTH_FAILED
    def get_allowed_auths(self, username):
        return "password" if username == "password" else "publickey"
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == "password" and password == "test-only-password" else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, channel_id):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

class Files(paramiko.SFTPServerInterface):
    def local(self, path):
        candidate = (root / path.lstrip("/")).resolve()
        if candidate != root and root not in candidate.parents:
            raise PermissionError(path)
        return candidate
    def list_folder(self, path):
        try:
            result = []
            for child in self.local(path).iterdir():
                value = paramiko.SFTPAttributes.from_stat(child.lstat())
                value.filename = child.name
                result.append(value)
            return result
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(self.local(path).stat())
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    lstat = stat
    def open(self, path, flags, attr):
        try:
            if path.endswith("Cancel-transfer.txt"):
                time.sleep(2)  # deterministic in-flight cancellation window
            fd = os.open(self.local(path), flags, 0o600)
            mode = "r+b" if flags & os.O_RDWR else "wb" if flags & os.O_WRONLY else "rb"
            file = os.fdopen(fd, mode)
            handle = paramiko.SFTPHandle(flags)
            handle.readfile = file
            handle.writefile = file
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    def rename(self, source, destination):
        try:
            if self.local(destination).exists():
                return paramiko.SFTP_FAILURE
            os.rename(self.local(source), self.local(destination))
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)
    def mkdir(self, path, attr):
        return self.mutate(path, lambda value: value.mkdir())
    def remove(self, path):
        return self.mutate(path, lambda value: value.unlink())
    def rmdir(self, path):
        return self.mutate(path, lambda value: value.rmdir())
    def mutate(self, path, action):
        try:
            action(self.local(path))
            return paramiko.SFTP_OK
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(20)
sftp_port = listener.getsockname()[1]
transports = []
def accept():
    while not stopped.is_set():
        try:
            client, _ = listener.accept()
        except OSError:
            return
        def session(client=client):
            try:
                transport = paramiko.Transport(client)
                transports.append(transport)
                transport.add_server_key(host_key)
                transport.set_subsystem_handler("sftp", paramiko.SFTPServer, Files)
                transport.start_server(server=Auth())
                while transport.is_active():
                    time.sleep(0.05)
            except Exception:
                client.close()
        threading.Thread(target=session, daemon=True).start()
ssh_thread = threading.Thread(target=accept, daemon=True)
ssh_thread.start()
print(json.dumps({"ftp": ftp.socket.getsockname()[1], "ftps": ftps.socket.getsockname()[1], "ca": str(ca_path), "sftp": sftp_port, "key": str(key_path),
                  "hostKeys": f"[127.0.0.1]:{sftp_port} {host_key.get_name()} {host_key.get_base64()}\n",
                  "wrongHostKeys": f"[127.0.0.1]:{sftp_port} {wrong_host_key.get_name()} {wrong_host_key.get_base64()}\n"}), flush=True)
for line in sys.stdin:
    if line.strip() == "stop":
        break
stopped.set()
ftp.close_all()
ftps.close_all()
for transport in transports:
    transport.close()
listener.close()
ftp_thread.join(timeout=2)
ssh_thread.join(timeout=2)
