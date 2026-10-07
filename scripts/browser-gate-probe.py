#!/usr/bin/env python3
"""Partial Gate 0 probe. No browser access, credentials, model turns or approvals.

Runs two inert MCP fixtures through the pinned real App Server. A successful
probe is NOT browser integration certification. Evidence remains app-owned.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

PIN = "codex-cli 0.155.0-alpha.16.4"
SCHEMA_PIN = "08b1a3d8ed1593fb086ccbc06ea740f494282adc8c9b82c18937de4ede72449d"


def fixture(label):
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion": request["params"]["protocolVersion"],
                      "capabilities": {"tools": {}},
                      "serverInfo": {"name": label, "version": "1.0.0"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "inspect", "description": "Return an inert fixture marker; no browser access.",
                                 "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}}]}
        elif method == "tools/call" and request.get("params", {}).get("name") == "inspect":
            result = {"content": [{"type": "text", "text": "fixture:" + label}], "isError": False}
        elif method == "ping":
            result = {}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                              "error": {"code": -32601, "message": "Unsupported fixture request"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


class Server:
    def __init__(self, executable, home, evidence):
        env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ}
        env["CODEX_HOME"] = str(home)
        self.process = subprocess.Popen(
            [str(executable), "app-server", "--listen", "stdio://",
             "-c", 'cli_auth_credentials_store="file"', "-c", "analytics.enabled=false"],
            cwd=home, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True)
        self.messages = queue.Queue()
        self.sequence = 0
        self.evidence = evidence
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        finally:
            self.messages.put(None)

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def request(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 30
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(method + ": uncertain; no retry")
            try:
                message = self.messages.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError(method + ": uncertain; no retry") from None
            if message is None:
                raise RuntimeError("Transport closed; no retry")
            if "method" in message:
                # Never approve an unsolicited request. Record names, not payloads.
                self.evidence.append({"event": message["method"]})
                if "id" in message:
                    self.send({"id": message["id"], "error": {"code": -32601, "message": "Unsupported probe request"}})
                continue
            if message.get("id") == request_id:
                self.evidence.append({"method": method, "outcome": "error" if "error" in message else "result"})
                return message

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            # Only this probe-owned server; no browser or shared daemon is touched.
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process.stdout.close()


def run(executable):
    version = subprocess.check_output([str(executable), "--version"], text=True).strip()
    if version != PIN:
        raise RuntimeError("Protocol pin mismatch: " + version)
    root = Path.home() / "Library/Application Support/Context Desk/browser-gate"
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    work = Path(tempfile.mkdtemp(prefix="scope-", dir=root))
    home = work / "home"
    home.mkdir(mode=0o700)
    schema = work / "schema"
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home), "CODEX_HOME": str(home)}
    subprocess.run([str(executable), "app-server", "generate-json-schema", "--experimental", "--out", str(schema)],
                   env=env, cwd=home, check=True, stdout=subprocess.DEVNULL, timeout=30)
    digest = hashlib.sha256()
    for path in sorted(schema.rglob("*.json")):
        digest.update(str(path.relative_to(schema)).encode())
        digest.update(path.read_bytes())
    if digest.hexdigest() != SCHEMA_PIN:
        raise RuntimeError("Generated protocol schema differs from the audited pin")
    report = {"codex": version, "schemaSHA256": digest.hexdigest(), "gatePassed": False,
              "scope": "inert MCP via direct App Server RPC, not model execution or browser control",
              "checks": [], "events": [], "pending": ["persisted history resume", "real driver attachment and images", "model tool discovery",
              "queued turns and interruption", "external cessation", "permission denial/revocation", "crash recovery"]}
    server = Server(executable, home, report["events"])
    try:
        result = server.request("initialize", {"clientInfo": {"name": "context_desk_browser_gate", "version": "0.1.0"},
                                               "capabilities": {"experimentalApi": True}})
        if "error" in result:
            raise RuntimeError("Initialize rejected")
        server.send({"method": "initialized", "params": {}})
        configurations = {name: {"command": sys.executable, "args": [str(Path(__file__).resolve()), "--fixture", name]}
                          for name in ("browser_a", "desktop_b")}
        threads = {}
        for selection in ("none", "browser_a", "desktop_b"):
            config = {"mcp_servers." + name: dict(value, enabled=(name == selection))
                      for name, value in configurations.items()}
            response = server.request("thread/start", {"cwd": str(home), "approvalPolicy": "untrusted",
                                                       "sandbox": "read-only", "config": config})
            if "error" in response:
                raise RuntimeError("Thread start rejected: " + str(response["error"].get("code")))
            threads[selection] = response["result"]["thread"]["id"]
        def check_scope(phase, selection, thread, connection=server):
            for integration in configurations:
                response = connection.request("mcpServer/tool/call", {"threadId": thread, "server": integration,
                                                                  "tool": "inspect", "arguments": {}})
                marker = "fixture:" + integration
                invoked = marker in json.dumps(response.get("result", {}))
                denied = response.get("error", {}).get("message") == "unknown MCP server '" + integration + "'"
                report["checks"].append({"phase": phase, "selection": selection, "integration": integration,
                                         "invoked": invoked, "rpcRejected": denied,
                                         "expected": "invoke" if selection == integration else "reject",
                                         "passed": invoked if selection == integration else denied,
                                         "errorCode": response.get("error", {}).get("code"),
                                         "error": response.get("error", {}).get("message")})
        for selection, thread in threads.items():
            check_scope("fresh", selection, thread)
        report["freshThreadScopePassed"] = all(check["passed"] for check in report["checks"])
        # Persist harmless synthetic history without calling a model or copying
        # credentials, so loaded/cold resume exercise a real stored thread.
        response = server.request("thread/inject_items", {"threadId": threads["browser_a"], "items": [
            {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "Inert browser gate fixture history. No model turn requested."}]}]})
        report["fixtureHistoryAccepted"] = "error" not in response
        response = server.request("thread/resume", {"threadId": threads["browser_a"],
                                  "config": {"mcp_servers." + name: dict(value, enabled=False)
                                             for name, value in configurations.items()}})
        report["loadedResumeAccepted"] = "error" not in response
        report["loadedResumeError"] = response.get("error")
        if "error" not in response:
            check_scope("loaded-resume-disabled", "none", threads["browser_a"])
            check_scope("other-thread-after-resume", "desktop_b", threads["desktop_b"])
        report["loadedResumeScopePassed"] = report["loadedResumeAccepted"] and all(
            check["passed"] for check in report["checks"] if check["phase"] != "fresh")
        # A separate process/home is an isolation candidate, not a proven
        # credential/session architecture. Do not copy the live app's auth.
        other_home = work / "isolated-home"
        other_home.mkdir(mode=0o700)
        other = Server(executable, other_home, report["events"])
        try:
            initialized = other.request("initialize", {"clientInfo": {"name": "context_desk_browser_gate", "version": "0.1.0"},
                                                        "capabilities": {"experimentalApi": True}})
            if "error" in initialized:
                raise RuntimeError("Isolated initialize rejected")
            other.send({"method": "initialized", "params": {}})
            response = other.request("thread/start", {"cwd": str(other_home), "approvalPolicy": "untrusted", "sandbox": "read-only"})
            if "error" in response:
                raise RuntimeError("Isolated thread start rejected")
            check_scope("isolated-process", "none", response["result"]["thread"]["id"], other)
            response = other.request("mcpServer/tool/call", {"threadId": threads["browser_a"], "server": "browser_a",
                                                           "tool": "inspect", "arguments": {}})
            report["foreignThreadRejected"] = "error" in response
            check_scope("original-after-isolated-process", "browser_a", threads["browser_a"])
            report["isolatedProcessScopePassed"] = report["foreignThreadRejected"] and all(
                c["passed"] for c in report["checks"] if c["phase"] in ("isolated-process", "original-after-isolated-process"))
        finally:
            other.close()
        cold = Server(executable, home, report["events"])
        try:
            response = cold.request("initialize", {"clientInfo": {"name": "context_desk_browser_gate", "version": "0.1.0"},
                                                   "capabilities": {"experimentalApi": True}})
            if "error" in response:
                raise RuntimeError("Cold initialize rejected")
            cold.send({"method": "initialized", "params": {}})
            response = cold.request("thread/resume", {"threadId": threads["browser_a"],
                                    "config": {"mcp_servers." + name: dict(value, enabled=False)
                                               for name, value in configurations.items()}})
            report["coldResumeAccepted"] = "error" not in response
            if "error" not in response:
                check_scope("cold-resume-disabled", "none", threads["browser_a"], cold)
            report["coldResumeScopePassed"] = report["coldResumeAccepted"] and all(
                c["passed"] for c in report["checks"] if c["phase"] == "cold-resume-disabled")
        finally:
            cold.close()
    finally:
        server.close()
        output = work / "report.json"
        output.write_text(json.dumps(report, indent=2) + "\n")
        output.chmod(0o600)
        print("Evidence: " + str(output))
    print(json.dumps({key: value for key, value in report.items() if key != "events"}, indent=2))
    # Never emit a success exit status for the complete gate from this partial probe.
    if report.get("loadedResumeAccepted") and not report.get("loadedResumeScopePassed"):
        return 1
    return 2 if report.get("freshThreadScopePassed") and report.get("isolatedProcessScopePassed") else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, default=Path("/Applications/ChatGPT.app/Contents/Resources/codex"))
    parser.add_argument("--fixture", choices=["browser_a", "desktop_b"])
    args = parser.parse_args()
    if args.fixture:
        fixture(args.fixture)
    else:
        sys.exit(run(args.codex))
