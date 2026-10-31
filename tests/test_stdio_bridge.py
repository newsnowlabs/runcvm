"""Local protocol/pipe tests; no Docker, VM, or installed runtime required.

Run: python3 -m unittest discover -s tests -p test_stdio_bridge.py -v
"""
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="runcvm-stdio-")
        if os.environ.get("RUNCVM_STDIO_BINARY"):
            cls.exe = os.environ["RUNCVM_STDIO_BINARY"]
            return
        cls.exe = str(Path(cls.build.name) / "runcvm-stdio")
        subprocess.run(["cc", "-std=gnu99", "-Wall", "-Wextra", "-Werror",
                        "-O2", "-o", cls.exe, str(ROOT / "runcvm-stdio/bridge.c")], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def pair(self, command, fragment=False):
        a, b = socket.socketpair()
        if fragment:
            c, d = socket.socketpair()
            def forward(src, dst):
                try:
                    while True:
                        chunk = src.recv(3)
                        if not chunk:
                            break
                        dst.sendall(chunk)
                except OSError:
                    pass
                finally:
                    try:
                        dst.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
            for src, dst in ((b, c), (c, b)):
                threading.Thread(target=forward, args=(src, dst), daemon=True).start()
            self.addCleanup(b.close)
            self.addCleanup(c.close)
            b = d
        host = subprocess.Popen([self.exe, "--host-fd", str(a.fileno())],
                                pass_fds=(a.fileno(),), stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        guest = subprocess.Popen([self.exe, "--guest-fd", str(b.fileno()), "--", *command],
                                 pass_fds=(b.fileno(),), stderr=subprocess.PIPE)
        a.close()
        b.close()
        def cleanup():
            for p in (host, guest):
                if p.poll() is None:
                    p.kill()
                p.wait()
                for f in (p.stdin, p.stdout, p.stderr):
                    if f:
                        f.close()
        self.addCleanup(cleanup)
        return host, guest

    def run_pair(self, command, data=b"", expected=0):
        host, guest = self.pair(command)
        out, err = host.communicate(data, timeout=15)
        self.assertEqual(guest.wait(timeout=3), expected, guest.stderr.read())
        self.assertEqual(host.returncode, expected, err)
        return out, err

    def test_original_sed(self):
        self.assertEqual(self.run_pair(["sed", "s/^/XXX /; s/$/YYY/;"], b"hello\n"),
                         (b"XXX helloYYY\n", b""))

    def test_empty(self):
        self.assertEqual(self.run_pair(["cat"]), (b"", b""))

    def test_binary_and_backpressure(self):
        data = bytes(range(256)) * 16384
        self.assertEqual(self.run_pair(["cat"], data), (data, b""))

    def test_partial_line(self):
        self.assertEqual(self.run_pair(["cat"], b"no newline"), (b"no newline", b""))

    def test_fragmented_transport(self):
        host, guest = self.pair(["cat"], fragment=True)
        data = bytes(range(256)) * 64
        self.assertEqual(host.communicate(data, timeout=10), (data, b""))
        self.assertEqual(host.returncode, 0)
        self.assertEqual(guest.wait(timeout=3), 0)

    def test_host_launch_and_qemu_exit_race(self):
        # A local stand-in accepts the QEMU chardev connection, hands it to the
        # real guest bridge, and exits immediately after the guest completes.
        fake = """import socket,subprocess,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
c,_=s.accept()
p=subprocess.Popen([sys.argv[2],'--guest-fd',str(c.fileno()),'--','cat'],pass_fds=(c.fileno(),))
c.close(); sys.exit(p.wait())
"""
        with tempfile.TemporaryDirectory() as tmp:
            sock = str(Path(tmp) / "stdio.sock")
            p = subprocess.run([self.exe, "--host", sock, "--", "python3", "-c", fake, sock, self.exe],
                               input=b"hello", capture_output=True, timeout=5)
            self.assertEqual((p.returncode, p.stdout, p.stderr), (0, b"hello", b""))
            self.assertEqual((Path(tmp) / "qemu.log").read_bytes(), b"")
            self.assertEqual((Path(tmp) / "exitcode").read_text(), "0\n")

    def test_streams_and_status(self):
        self.assertEqual(self.run_pair(["sh", "-c", "printf out; printf err >&2; exit 37"], expected=37),
                         (b"out", b"err"))

    def test_output_before_reading_input(self):
        code = "import os; os.write(1,b'x'*1048576); os.write(2,b'y'*1048576); data=b''\nwhile True:\n b=os.read(0,65536)\n if not b: break\n data+=b\nos.write(1,data)"
        data = b"input" * 200000
        out, err = self.run_pair(["python3", "-c", code], data)
        self.assertEqual(out, b"x" * 1048576 + data)
        self.assertEqual(err, b"y" * 1048576)

    def test_persistent_eof_and_work_after_eof(self):
        code = "import os,time; assert os.read(0,1)==b''; assert os.read(0,1)==b''; time.sleep(.1); os.write(1,b'done')"
        self.assertEqual(self.run_pair(["python3", "-c", code]), (b"done", b""))

    def test_application_pipe_and_session(self):
        code = "import os,stat; assert stat.S_ISFIFO(os.fstat(0).st_mode); assert os.getsid(0)==os.getpid(); assert os.getpgrp()==os.getpid()"
        self.assertEqual(self.run_pair(["python3", "-c", code]), (b"", b""))

    def test_child_closes_input_early(self):
        self.assertEqual(self.run_pair(["sh", "-c", "exec 0<&-; sleep .1; printf done"], b"x" * 1048576),
                         (b"done", b""))

    def test_missing_command(self):
        out, err = self.run_pair(["/no-such-runcvm-command"], expected=127)
        self.assertEqual(out, b"")
        self.assertIn(b"exec", err)

    def test_signal_forwarding(self):
        host, guest = self.pair(["sh", "-c", "printf ready; exec sleep 60"])
        self.assertEqual(host.stdout.read(5), b"ready")
        host.send_signal(signal.SIGTERM)
        out, err = host.communicate(timeout=5)
        self.assertEqual((out, err), (b"", b""))
        self.assertEqual(host.returncode, 143)
        self.assertEqual(guest.wait(timeout=3), 143)

    def test_disconnect_is_failure(self):
        a, b = socket.socketpair()
        with subprocess.Popen([self.exe, "--guest-fd", str(b.fileno()), "--", "sleep", "60"],
                              pass_fds=(b.fileno(),), stderr=subprocess.PIPE) as guest:
            b.close()
            a.close()
            _, err = guest.communicate(timeout=3)
            self.assertEqual(guest.returncode, 125, err)

    def test_invalid_protocol(self):
        a, b = socket.socketpair()
        with subprocess.Popen([self.exe, "--guest-fd", str(b.fileno()), "--", "sleep", "60"],
                              pass_fds=(b.fileno(),), stderr=subprocess.PIPE) as guest:
            b.close()
            a.sendall(b"R" + struct.pack("!I", 4) + b"BAD!")
            _, err = guest.communicate(timeout=3)
            a.close()
            self.assertEqual(guest.returncode, 125, err)


class ModeTests(unittest.TestCase):
    def mode(self, stdin=None, **env):
        p = subprocess.run(["bash", "-c", '. "$1"; printf "%s %s" "$RUNCVM_STDIO_BRIDGE" "${RUNCVM_INIT:-0}"',
                            "bash", str(ROOT / "runcvm-scripts/runcvm-stdio-mode")],
                           stdin=stdin, capture_output=True,
                           env={"PATH": os.environ["PATH"], **env})
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_no_input(self):
        self.assertEqual(self.mode(subprocess.DEVNULL), b"0 0")

    def test_pipe(self):
        self.assertEqual(self.mode(subprocess.PIPE), b"1 1")

    def test_legacy(self):
        self.assertEqual(self.mode(subprocess.PIPE, RUNCVM_LEGACY_STDIO="1"), b"0 0")

    def test_explicit_init_preserved(self):
        self.assertEqual(self.mode(subprocess.PIPE, RUNCVM_LEGACY_STDIO="1", RUNCVM_INIT="1"), b"0 1")

    def test_terminal(self):
        import pty
        m, s = pty.openpty()
        try:
            self.assertEqual(self.mode(s), b"0 0")
        finally:
            os.close(m)
            os.close(s)

    def test_force_pipe(self):
        self.assertEqual(self.mode(subprocess.DEVNULL, RUNCVM_STDIO="pipe"), b"1 1")


if __name__ == "__main__":
    unittest.main()
