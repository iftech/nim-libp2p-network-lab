"""Exercise the real node processes over loopback, including their exit codes."""

import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BOOTSTRAP, GOSSIPSUB = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])
sys.argv[1:3] = []


class NodeProcesses(unittest.TestCase):
    def run_network(self, transport, count=2):
        kind = socket.SOCK_DGRAM if transport == "QUIC" else socket.SOCK_STREAM
        with socket.socket(socket.AF_INET, kind) as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        address = (f"/ip4/127.0.0.1/udp/{port}/quic-v1" if transport == "QUIC"
                   else f"/ip4/127.0.0.1/tcp/{port}")
        listen = ("/ip4/127.0.0.1/udp/0/quic-v1" if transport == "QUIC"
                  else "/ip4/127.0.0.1/tcp/0")
        base = {**os.environ, "TRANSPORT": transport, "PARTICIPANTS": str(count),
                "MESSAGE_ROUNDS": "3", "DELIVERY_PERCENT": "99",
                "SELF_CHECK_TIMEOUT_SECS": "150", "STARTUP_JITTER_STEP_MS": "10"}
        processes = []
        files = []
        with tempfile.TemporaryDirectory() as directory:
            try:
                def start(binary, name, extra):
                    log = open(Path(directory) / name, "w+")
                    files.append(log)
                    proc = subprocess.Popen([binary], env={**base, **extra},
                                            stdout=log, stderr=subprocess.STDOUT)
                    processes.append(proc)
                    return proc

                boot = start(BOOTSTRAP, "bootstrap.log", {"LISTEN_ADDR": address})
                nodes = [start(GOSSIPSUB, f"node-{i}.log",
                               {"LISTEN_ADDR": listen, "BOOTSTRAP_HOST": "localhost",
                                "BOOTSTRAP_PORT": str(port), "NODE_INDEX": str(i)}) for i in range(count)]
                deadline = time.monotonic() + 170
                codes = [p.wait(timeout=max(1, deadline - time.monotonic())) for p in nodes]
                boot.send_signal(signal.SIGTERM)
                boot_code = boot.wait(timeout=15)
                self.assertEqual([boot_code, *codes], [0] * (count + 1))
                for log in files[1:]:
                    log.flush()
                    self.assertIn("GossipSub self-check passed", Path(log.name).read_text())
            except Exception:
                for log in files:
                    log.flush()
                    print(f"\n--- {log.name} ---\n{Path(log.name).read_text()}", file=sys.stderr)
                raise
            finally:
                for proc in processes:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait()
                for log in files:
                    log.close()

    def test_tcp(self):
        self.run_network("TCP")

    def test_quic(self):
        self.run_network("QUIC")

    def test_tcp_scaled(self):
        self.run_network("TCP", int(os.environ.get("NETWORK_LAB_TEST_SCALE", "10")))

    def test_missing_participant_fails(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        address = f"/ip4/127.0.0.1/tcp/{port}"
        base = {**os.environ, "TRANSPORT": "TCP", "PARTICIPANTS": "2",
                "SELF_CHECK_TIMEOUT_SECS": "6", "STARTUP_JITTER_STEP_MS": "0"}
        with tempfile.TemporaryDirectory() as directory:
            with open(Path(directory) / "bootstrap.log", "w+") as boot_log, \
                 open(Path(directory) / "node.log", "w+") as node_log:
                boot = subprocess.Popen([BOOTSTRAP], env={**base, "LISTEN_ADDR": address},
                                        stdout=boot_log, stderr=subprocess.STDOUT)
                node = subprocess.Popen([GOSSIPSUB], env={**base, "NODE_INDEX": "0",
                                        "LISTEN_ADDR": "/ip4/127.0.0.1/tcp/0",
                                        "BOOTSTRAP_ADDR": address},
                                        stdout=node_log, stderr=subprocess.STDOUT)
                try:
                    self.assertEqual(boot.wait(timeout=45), 1)
                    self.assertEqual(node.wait(timeout=45), 1)
                    boot_log.flush()
                    self.assertIn("Bootstrap coordination timed out", Path(boot_log.name).read_text())
                finally:
                    for process in (boot, node):
                        if process.poll() is None:
                            process.kill()
                        process.wait()

    def test_default_listen_address_starts_both_nodes(self):
        # Run separately because both default to port 9000.
        env = {**os.environ, "TRANSPORT": "TCP", "PARTICIPANTS": "2",
               "SELF_CHECK_TIMEOUT_SECS": "15", "STARTUP_JITTER_STEP_MS": "0"}
        env.pop("LISTEN_ADDR", None)
        for binary, started in ((BOOTSTRAP, "Bootstrap started"),
                                (GOSSIPSUB, "GossipSub node started")):
            with self.subTest(binary=binary), tempfile.TemporaryFile(mode="w+") as log:
                process = subprocess.Popen([binary], env=env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    output = ""
                    while time.monotonic() < deadline:
                        log.seek(0)
                        output = log.read()
                        if started in output or process.poll() is not None:
                            break
                        time.sleep(0.1)
                    self.assertIn(started, output)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait()

    def test_invalid_configuration_fails(self):
        for binary, role in ((BOOTSTRAP, "bootstrap"), (GOSSIPSUB, "gossipsub")):
            with self.subTest(role=role):
                result = subprocess.run([binary], env={**os.environ, "TRANSPORT": "invalid"},
                                        capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 1)
                output = result.stdout + result.stderr
                line = next(line for line in output.splitlines()
                            if line.startswith("NETWORK_LAB_FAILURE "))
                failure = json.loads(line.removeprefix("NETWORK_LAB_FAILURE "))
                self.assertEqual((failure["role"], failure["phase"], failure["category"]),
                                 (role, "startup", "configuration"))
                self.assertIn("TRANSPORT", failure["message"])

    def test_unreachable_bootstrap_fails(self):
        env = {**os.environ, "TRANSPORT": "TCP", "PARTICIPANTS": "2", "NODE_INDEX": "0",
               "LISTEN_ADDR": "/ip4/127.0.0.1/tcp/0",
               "BOOTSTRAP_ADDR": "/ip4/127.0.0.1/tcp/1/p2p/12D3KooWLbteJ8m8KoVktnMLH3oYKJcJRmrNdcKpk88vfZ5x5wSq", "SELF_CHECK_TIMEOUT_SECS": "3",
               "STARTUP_JITTER_STEP_MS": "0"}
        result = subprocess.run([GOSSIPSUB], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cannot connect to bootstrap", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
