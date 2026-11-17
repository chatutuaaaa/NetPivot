"""Exercise nine WireGuard clients in separate Linux network namespaces."""
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

BASE = "http://127.0.0.1:8080"
ECHO = """
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((sys.argv[1], 24642))
while True:
    data, peer = s.recvfrom(1024)
    s.sendto(data, peer)
"""
PROBE = """
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(float(sys.argv[4]))
s.bind((sys.argv[1], 0))
s.sendto(b'NPT1abcdefghijklmnop', (sys.argv[2], int(sys.argv[3])))
try:
    assert s.recv(1024) == b'NPT1abcdefghijklmnop'
except TimeoutError:
    sys.exit(3)
"""


def api(method, path, token="", body=None):
    headers = {"Authorization": "Bearer " + token, "Idempotency-Key": str(uuid.uuid4())}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, headers=headers, data=data, method=method)
    with urllib.request.urlopen(req, timeout=4) as response:
        data = response.read()
        return json.loads(data) if data else None


def retry(call, limit=12):
    for i in range(limit):
        try:
            return call()
        except urllib.error.HTTPError as exc:
            if exc.code != 503 or i == limit - 1:
                raise
        except urllib.error.URLError:
            if i == limit - 1:
                raise
        time.sleep(0.4)


def b64(value):
    return base64.b64encode(value).decode()


def register(index):
    private = Ed25519PrivateKey.generate()
    public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    challenge = api("POST", "/v1/auth/challenges", body={"public_key": b64(public)})["challenge"]
    signature = private.sign(("NetPivot session v1\n" + challenge).encode())
    return api("POST", "/v1/sessions", body={
        "challenge": challenge, "signature": b64(signature), "name": f"Lab {index}"
    })


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


class Client:
    def __init__(self, index, identity, network_id):
        self.name = f"np{index}"
        self.token = identity["token"]
        self.device_id = identity["device_id"]
        self.network_id = network_id
        prefix = f"172.31.{index}"
        outside = f"npv{index}"
        key_path = f"/tmp/{self.name}.wg"
        with open(key_path, "w") as key_file:
            run("wg", "genkey", stdout=key_file)
        with open(key_path) as key_file:
            public = run("wg", "pubkey", stdin=key_file, capture_output=True).stdout.strip()
        path = f"/v1/networks/{network_id}"
        api("POST", path + "/connect", self.token, {"public_key": public})
        config = retry(lambda: api("GET", path + "/config", self.token))
        self.address = config["address"].split("/")[0]
        self.lease_id = config["lease_id"]
        run("ip", "netns", "add", self.name)
        run("ip", "link", "add", outside, "type", "veth", "peer", "name", "eth0", "netns", self.name)
        run("ip", "addr", "add", prefix + ".1/30", "dev", outside)
        run("ip", "link", "set", outside, "up")
        self.inside("ip", "addr", "add", prefix + ".2/30", "dev", "eth0")
        self.inside("ip", "link", "set", "eth0", "up")
        self.inside("ip", "link", "set", "lo", "up")
        self.inside("ip", "route", "add", "default", "via", prefix + ".1")
        self.inside("ip", "link", "add", "wg0", "type", "wireguard")
        self.inside("ip", "addr", "add", config["address"], "dev", "wg0")
        # Deliberately route the entire test pool to exercise server isolation
        # even when a modified client attempts to reach another network.
        self.inside("wg", "set", "wg0", "private-key", key_path, "peer", config["public_key"],
                    "allowed-ips", "10.203.0.0/16", "endpoint", config["endpoint"], "persistent-keepalive", "25")
        self.inside("ip", "link", "set", "wg0", "mtu", str(config["mtu"]), "up")
        self.inside("ip", "route", "add", "10.203.0.0/16", "dev", "wg0")
        self.echo = subprocess.Popen(["ip", "netns", "exec", self.name, "python3", "-c", ECHO, self.address])

    def inside(self, *args):
        return run("ip", "netns", "exec", self.name, *args)

    def probe(self, IP, port="24642", limit="0.55"):
        res = subprocess.run(["ip", "netns", "exec", self.name, "python3", "-c", PROBE,
                              self.address, IP, port, limit], check=False)
        if res.returncode not in (0, 3):
            raise RuntimeError(f"unexpected probe error {res.returncode}")
        return res.returncode == 0


def main():
    retry(lambda: api("GET", "/readyz"))
    clients = []
    try:
        owner = register(1)
        network = api("POST", "/v1/networks", owner["token"], {"name": "Eight devices"})
        net_path = "/v1/networks/" + network["id"]
        invite = api("POST", net_path + "/invitations", owner["token"])
        url_token = urllib.parse.parse_qs(urllib.parse.urlsplit(invite["url"]).fragment)["t"][0]
        clients.append(Client(1, owner, network["id"]))
        for index in range(2, 9):
            device = register(index)
            api("POST", "/v1/invitations/redeem", device["token"], {"credential": url_token if index == 2 else invite["code"]})
            clients.append(Client(index, device, network["id"]))
        outsider = register(9)
        other = api("POST", "/v1/networks", outsider["token"], {"name": "Isolated"})
        clients.append(Client(9, outsider, other["id"]))
        for client in clients:
            assert client.probe("10.203.0.1", "41820", "2"), f"{client.name} cannot reach gateway"
        pairs = [(src, dst) for src in clients[:8] for dst in clients[:8] if src is not dst]
        with ThreadPoolExecutor(max_workers=8) as executor:
            replies = executor.map(lambda pair: pair[0].probe(pair[1].address, limit="2"), pairs)
            for (src, dst), reply in zip(pairs, replies):
                assert reply, f"{src.name} cannot reach {dst.name}"
        print("PASS: 8 members, all 56 directed UDP paths via WireGuard", flush=True)
        clients[1].inside("wg", "set", "wg0", "listen-port", "49921")
        assert clients[1].probe(clients[0].address, limit="2"), "cannot send after changing WireGuard UDP port"
        assert clients[0].probe(clients[1].address, limit="2"), "gateway did not update the peer endpoint"
        print("PASS: WireGuard session recovered after a UDP source port change", flush=True)
        assert not clients[0].probe(clients[8].address)
        assert not clients[8].probe(clients[0].address)
        print("PASS: cross-network packets blocked in both directions", flush=True)
        target = clients[7]
        api("DELETE", net_path + "/members/" + target.device_id, owner["token"])
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if not clients[0].probe(target.address):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("revoked peer continued to receive packets")
        assert not target.probe(clients[0].address)
        assert clients[0].probe(clients[1].address), "remaining peers interrupted"
        print("PASS: removed peer blocked without disrupting remaining peers", flush=True)
    finally:
        for client in clients:
            client.echo.terminate()
        for client in clients:
            client.echo.wait(timeout=4)


if __name__ == "__main__":
    main()
