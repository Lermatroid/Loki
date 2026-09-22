#!/usr/bin/env python3
"""Exercise only port 3010; all remote test files and services are temporary."""
import json
import os
from pathlib import Path
import queue
import re
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
SSH = ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", "ConnectTimeout=8", "-o", "ControlPath=none", "-o", "ClearAllForwardings=yes", "tinytroid"]
REMOTE = r'''
import http.server, json, os, pathlib, subprocess, sys, tempfile, threading
with tempfile.TemporaryDirectory(prefix="loki-fixture-") as temporary:
    repo = pathlib.Path(temporary) / "loki-test-app"
    repo.mkdir()
    subprocess.run(["/usr/bin/git", "init", "-q", "-b", "feature/loki-test", str(repo)], check=True)
    os.chdir(repo)
    code = 200
    server = None
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
        def do_GET(self):
            self.do_HEAD()
            self.wfile.write(b"Loki integration fixture\n")
        def log_message(self, *args): pass
    def start():
        global server
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 3010), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    def stop():
        global server
        if server:
            server.shutdown()
            server.server_close()
            server = None
    try:
        start()
        print("READY " + str(repo), flush=True)
        for line in sys.stdin:
            command = line.strip()
            if command == "stop": stop()
            elif command == "start": start()
            elif command == "error": code = 500
            elif command == "healthy": code = 200
            elif command == "branch":
                subprocess.run(["/usr/bin/git", "symbolic-ref", "HEAD", "refs/heads/feature/loki-second"], check=True)
            elif command == "quit": break
            print("ACK " + command, flush=True)
    finally:
        stop()
        os.chdir("/")
'''


def listeners():
    result = subprocess.run(["/usr/sbin/lsof", "-nP", "-iTCP:3000-3009", "-sTCP:LISTEN", "-Fpcn"], capture_output=True, text=True)
    return sorted(line for line in result.stdout.splitlines() if line.startswith(("p", "c", "n")))


def lines(process, history=None):
    output = queue.Queue()
    def read():
        for line in process.stdout:
            line = line.rstrip()
            if history is not None:
                history.append(line)
            output.put(line)
        output.put(None)
    threading.Thread(target=read, daemon=True).start()
    return output


def wait_for(output, predicate, timeout=20):
    deadline = time.monotonic() + timeout
    seen = []
    while time.monotonic() < deadline:
        try:
            line = output.get(timeout=max(0.01, deadline - time.monotonic()))
        except queue.Empty:
            break
        if line is None:
            break
        seen.append(line)
        print(line, flush=True)
        if predicate(line):
            return line
    raise AssertionError("Expected state not observed. Recent output: " + repr(seen))


def main():
    before = listeners()
    # Fail before doing any work if another app already owns the test port.
    with socket.socket() as reservation:
        reservation.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        reservation.bind(("127.0.0.1", 3010))
    fixture = subprocess.Popen(SSH + ["/usr/bin/python3 -u -c " + shlex.quote(REMOTE)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    fixture_lines = lines(fixture)
    diagnostic = None
    history = []
    checks = []
    def control(command):
        fixture.stdin.write(command + "\n")
        fixture.stdin.flush()
        wait_for(fixture_lines, lambda line: line == "ACK " + command)
    try:
        wait_for(fixture_lines, lambda line: line.startswith("READY "))
        diagnostic = subprocess.Popen([str(ROOT / ".build/debug/Loki"), "--diagnose", "--duration", "85"],
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        output = lines(diagnostic, history)
        ready = wait_for(output, lambda line: "Responding" in line and "project=loki-test-app" in line and "branch=feature/loki-test" in line)
        checks.append("Forward responds and project/branch are detected")
        for url in ["http://127.0.0.1:3010", "http://[::1]:3010"]:
            response = subprocess.check_output(["/usr/bin/curl", "--noproxy", "*", "--fail", "--silent", "--max-time", "5", url], text=True)
            assert response == "Loki integration fixture\n"
        checks.append("IPv4 and IPv6 loopback both reach the remote fixture")
        first_pid = int(re.search(r"sshPID=(\d+)", ready).group(1))
        os.kill(first_pid, signal.SIGTERM)
        recovered = wait_for(output, lambda line: "Responding" in line and "sshPID=" + str(first_pid) + " " not in line, timeout=25)
        second_pid = int(re.search(r"sshPID=(\d+)", recovered).group(1))
        checks.append("Terminating Loki's own SSH process automatically reconnects")
        control("error")
        bad_response = wait_for(output, lambda line: "HTTP 500" in line)
        assert "sshPID=" + str(second_pid) + " " in bad_response
        checks.append("HTTP 500 is shown without restarting SSH")
        control("healthy")
        control("branch")
        wait_for(output, lambda line: "Responding" in line and "branch=feature/loki-second" in line)
        checks.append("Branch changes refresh while the server stays running")
        control("stop")
        wait_for(output, lambda line: "Waiting for remote service" in line)
        control("start")
        wait_for(output, lambda line: "Responding" in line and "branch=feature/loki-second" in line)
        checks.append("Stopping and restarting the service recovers without restarting Loki")
        diagnostic.wait(timeout=90)
        assert diagnostic.returncode == 0
        with socket.socket() as conflict:
            conflict.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            conflict.bind(("127.0.0.1", 3010))
            conflict.listen()
            result = subprocess.run([str(ROOT / ".build/debug/Loki"), "--diagnose", "--duration", "3"], capture_output=True, text=True, timeout=12)
            assert "Local port 3010 is used by" in result.stdout, result.stdout
        checks.append("Local port conflicts identify the owner and leave it running")
        after = listeners()
        assert before == after, "Existing 3000–3009 listeners changed during the test."
        checks.append("Existing local listeners on 3000–3009 are unchanged")
        report = ROOT / ".local/integration-results.json"
        report.parent.mkdir(exist_ok=True)
        report.write_text(json.dumps({"passed": checks, "existingListeners": before, "diagnostic": history}, indent=2) + "\n")
        print("PASS: " + "\nPASS: ".join(checks), flush=True)
        print("Report: " + str(report), flush=True)
    finally:
        if diagnostic and diagnostic.poll() is None:
            # Diagnostics owns cleanup; allow its bounded run to release the forward.
            diagnostic.wait(timeout=95)
        if fixture.poll() is None:
            try:
                fixture.stdin.write("quit\n")
                fixture.stdin.flush()
                fixture.stdin.close()
            except BrokenPipeError:
                pass
            fixture.wait(timeout=10)


if __name__ == "__main__":
    main()
