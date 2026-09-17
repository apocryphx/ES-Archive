#!/usr/bin/env python3
"""Onboarding drill: who greets after Claude Desktop's probe handoff.

Replays Desktop's launch against the real ES Archive MCP binary, in an isolated
fake HOME (own socket, own empty Core Data store), in Full (Dock) mode with the
onboarding window itself suppressed (-ESShowMainWindowAtLaunch NO) so the drill
can run unattended; the greet decision is read from the stderr log lines.
Scenario, as traced live on 2026-09-17 (design-decisions/mid-session-reelection.md):
  A (the probe) hosts → B relays → A's stdin closes and SIGTERM arrives, A lingers
  for B → A is SIGKILLed only 3.5 s later, well after its 2 s greet timer fired
  → B is promoted by re-election within the startup window and greets
  → C relays to B → 31 s later B is SIGKILLed → C is promoted mid-session and
  must stay quiet.
Checks: A's timer stands down (session ended), A never greets, B greets, C never
greets, and each promotion happens.
"""
import json, os, queue, shutil, signal, subprocess, sys, threading, time

APP = sys.argv[1]; FAKE_HOME = sys.argv[2]
shutil.rmtree(FAKE_HOME, ignore_errors=True); os.makedirs(FAKE_HOME)
SOCK = os.path.join(FAKE_HOME, "engine.sock")
DEV_STORE_DIR = os.path.expanduser("~/Library/Application Support/ES Archive MCP/")
# Created by (and only by) unsigned test hosts like this one; start from empty.
shutil.rmtree(DEV_STORE_DIR, ignore_errors=True)
env = dict(os.environ, HOME=FAKE_HOME, UDS_SOCKET_PATH=SOCK)
env.pop("CFFIXED_USER_HOME", None)

class Proc:
    def __init__(self, name):
        self.name = name; self.t0 = time.time()
        self.p = subprocess.Popen(
            [APP, "--author", name, "-ESActivationMode", "0", "-ESShowMainWindowAtLaunch", "NO"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)
        self.out = queue.Queue(); self.err = []
        threading.Thread(target=self._pump_out, daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()
    def _pump_out(self):
        for line in iter(self.p.stdout.readline, b""):
            self.out.put(line.decode("utf-8", "replace"))
    def _pump_err(self):
        for line in iter(self.p.stderr.readline, b""):
            s = line.decode("utf-8", "replace").rstrip(); self.err.append(s)
            if "es-archive-mcp" in s: print(f"    +{time.time()-self.t0:5.2f}s [{self.name}] {s}", flush=True)
    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode()); self.p.stdin.flush()
    def init(self):
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "e2e", "version": "0"}}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    def alive(self): return self.p.poll() is None
    def has(self, needle): return any(needle in s for s in self.err)
    def wait_for(self, needle, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.has(needle): return True
            time.sleep(0.05)
        return False

results = []
def ok(cond, name):
    results.append(cond); print(("  ✓ " if cond else "  ✗ ") + name, flush=True)

GREETED = "] greeting —"                       # the actual greet line (not "not greeting")
STOOD_DOWN = "not greeting — own stdio session already ended"
PROMOTED_GREET = "greeting — onboarding and focus (host by re-election during startup)"

try:
    print("[phase 1] probe A hosts, real instance B relays")
    A = Proc("A"); A.init(); ok(A.wait_for("serving locally", 30), "A: hosts")
    # Isolation guard, same as the re-election drill: never the live archive.
    lsof = subprocess.run(["lsof", "-Fn", "-p", str(A.p.pid)], capture_output=True, text=True).stdout
    stores = [l[1:] for l in lsof.splitlines() if l.startswith("n") and ".sqlite" in l]
    if not stores or any(not f.startswith((FAKE_HOME, DEV_STORE_DIR)) or "/Containers/" in f for f in stores):
        raise SystemExit("ABORT: host store is not isolated: %r" % stores)
    ok(True, "A: Core Data store isolated")
    B = Proc("B"); B.init(); ok(B.wait_for("relay — headless", 20), "B: relays to A")
    time.sleep(0.3)

    print("[phase 2] Desktop closes the probe: stdin EOF, SIGTERM; SIGKILL only 3.5 s later")
    A.p.stdin.close(); time.sleep(0.05); A.p.send_signal(signal.SIGTERM)
    time.sleep(3.5)
    ok(A.has("lingering as host"), "A: lingered for its peer after its session ended")
    ok(A.has(STOOD_DOWN), "A: greet timer fired but stood down — own session already ended")
    ok(not A.has(GREETED), "A: never greeted, although it outlived its timer")
    A.p.send_signal(signal.SIGKILL); A.p.wait()
    ok(B.wait_for("now hosts the engine", 20), "B: promoted by re-election")
    ok(B.wait_for(PROMOTED_GREET, 6), "B: greeted ~2 s after promotion (within the startup window)")

    print("[phase 3] mid-session: C relays; B dies 31 s after C launched (past the 30 s startup window)")
    C = Proc("C"); C.init(); ok(C.wait_for("relay — headless", 20), "C: relays to B")
    time.sleep(31)
    B.p.send_signal(signal.SIGKILL); B.p.wait()
    ok(C.wait_for("now hosts the engine", 20), "C: promoted by re-election")
    time.sleep(3)
    ok(not C.has(GREETED), "C: promoted mid-session, did not greet")
    C.p.stdin.close()
    try: C.p.wait(timeout=20); ok(True, "C: exited on stdin EOF")
    except subprocess.TimeoutExpired: ok(False, "C: exited on stdin EOF")
finally:
    for p in [x for x in globals().values() if isinstance(x, Proc)]:
        if p.alive(): p.p.kill()
    time.sleep(0.5)
    shutil.rmtree(DEV_STORE_DIR, ignore_errors=True)

print(f"\n{sum(results)} passed, {len(results)-sum(results)} failed")
sys.exit(0 if all(results) else 1)
