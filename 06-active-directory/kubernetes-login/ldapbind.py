#!/usr/bin/env python3
"""LDAP simple bind over LDAPS using only the Python stdlib. Exit 0 if AD accepts DN/password.
   ldapbind.py HOST CAFILE BIND_DN      (password read from env BINDPW)"""
import os, socket, ssl, sys
host, cafile, dn = sys.argv[1:4]; pw = os.environ.get("BINDPW", "")
def tlv(tag, val): 
    n = len(val)
    ln = bytes([n]) if n < 128 else (bytes([0x81, n]) if n < 256 else bytes([0x82, n >> 8, n & 255]))
    return bytes([tag]) + ln + val
bind = tlv(0x60, tlv(0x02, b"\x03") + tlv(0x04, dn.encode()) + tlv(0x80, pw.encode()))
msg = tlv(0x30, tlv(0x02, b"\x01") + bind)
ctx = ssl.create_default_context(cafile=cafile)
with socket.create_connection((host, 636), timeout=10) as s, ctx.wrap_socket(s, server_hostname=host) as t:
    t.sendall(msg); r = t.recv(4096)
# BindResponse: 0x61 <len (short or long form)> 0x0a 0x01 <resultCode>
code = -1
i = r.find(b"\x61")
if i >= 0:
    j = i + 1
    j += 1 + (r[j] & 0x7f) if r[j] & 0x80 else 1
    if r[j:j + 2] == b"\x0a\x01":
        code = r[j + 2]
print({0: "OK - AD accepted the password", 49: "REJECTED - invalid credentials (49)"}.get(code, f"LDAP result code {code}"))
sys.exit(0 if code == 0 else 1)
