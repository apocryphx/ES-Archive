#!/usr/bin/env python3
"""End-to-end host-loss drill against the real ES Archive MCP binary.

Runs in an isolated fake HOME (own App Group socket, own empty Core Data store),
so nothing touches the live archive. Scenario:
  A host; B, C relays → SIGKILL A → B and C re-elect (one hosts, one relays)
  → close new host's stdin → it lingers for the other → close the other's stdin
  → both exit.
"""
import json, os, signal, subprocess, sys, threading, queue, time, shutil

APP = sys.argv[1]
MODE_MENUBAR = sys.argv[2]
FAKE_HOME = sys.argv[3]
# Optional 4th arg: a trace file. Every stderr line of every process is appended
# there with wall-clock time and process name, and the binaries run with
# ES_ARCHIVE_TRACE=1 so the election / socket trace points (ESTrace) fire.
TRACE = open(sys.argv[4], "w") if len(sys.argv) > 4 and sys.argv[4] else None
shutil.rmtree(FAKE_HOME, ignore_errors=True)
os.makedirs(FAKE_HOME)
SOCK = os.path.join(FAKE_HOME, "engine.sock")
DEV_STORE_DIR = os.path.expanduser("~/Library/Application Support/ES Archive MCP/")
# Created by (and only by) unsigned test hosts like this one; start from empty.
shutil.rmtree(DEV_STORE_DIR, ignore_errors=True)
env = dict(os.environ, HOME=FAKE_HOME, UDS_SOCKET_PATH=SOCK)
if TRACE: env["ES_ARCHIVE_TRACE"] = "1"
for k in ("CFFIXED_USER_HOME",):
    env.pop(k, None)

class Proc:
    def __init__(self, name):
        self.name = name
        self.p = subprocess.Popen(
            [APP, "--author", name, "-ESActivationMode", MODE_MENUBAR,
             "-ESShowMainWindowAtLaunch", "NO"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, bufsize=0)
        self.out = queue.Queue(); self.err = []
        threading.Thread(target=self._pump, args=(self.p.stdout, self.out), daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()
        self.nid = 0
    def _pump(self, f, q):
        for line in iter(f.readline, b""):
            q.put(line.decode("utf-8", "replace"))
    def _pump_err(self):
        for line in iter(self.p.stderr.readline, b""):
            s = line.decode("utf-8", "replace").rstrip()
            self.err.append(s)
            if TRACE:
                TRACE.write(f"{time.strftime('%H:%M:%S')}.{int((time.time()%1)*1000):03d} [{self.name}] {s}\n"); TRACE.flush()
            if "es-archive-mcp" in s: print(f"    [{self.name} stderr] {s}", flush=True)
    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode()); self.p.stdin.flush()
    def call(self, method, params=None, timeout=90):
        self.nid += 1; rid = self.nid
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try: line = self.out.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty: break
            try: msg = json.loads(line)
            except Exception: continue
            if msg.get("id") == rid: return msg
        return None
    def init(self):
        r = self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "e2e", "version": "0"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r
    def close_stdin(self): self.p.stdin.close()
    def alive(self): return self.p.poll() is None
    def has(self, needle): return any(needle in s for s in self.err)
    def final_role(self):
        # The role this process ended up in: its LAST "re-elected —" line. A relay
        # can transiently connect to the dead host's listen socket during kernel
        # teardown (connect succeeds, then EOF) and re-elect a second time; only
        # the settled role matters.
        roles = [s for s in self.err if "re-elected —" in s]
        if not roles: return None
        return "host" if "now hosts the engine" in roles[-1] else "relay"
    def wait_for(self, needle, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.has(needle): return True
            time.sleep(0.1)
        return False

results = []
def ok(cond, name):
    results.append(cond); print(("  ✓ " if cond else "  ✗ ") + name, flush=True)

def tools_ok(p, label):
    r = p.call("tools/list")
    names = [t["name"] for t in (r or {}).get("result", {}).get("tools", [])]
    ok("archive_cli" in names and len(names) > 5, f"{label}: tools/list serves {len(names)} tools")
    return r

def cli_ok(p, label):
    r = p.call("tools/call", {"name": "archive_cli", "arguments": {"expression": "man"}})
    text = ((r or {}).get("result", {}).get("content") or [{}])[0].get("text", "")
    ok("error" not in (r or {}) and len(text) > 50, f"{label}: archive_cli(man) round-trips through the engine")

try:
    print("[phase 1] A hosts, B and C relay")
    A = Proc("A"); ok(A.init() is not None, "A: initialize")
    ok(A.wait_for("serving locally", 20), "A: serving locally (host)")
    # Isolation guard: the host's store must live under the fake HOME, never the live archive.
    lsof = subprocess.run(["lsof", "-Fn", "-p", str(A.p.pid)], capture_output=True, text=True).stdout
    stores = [l[1:] for l in lsof.splitlines() if l.startswith("n") and ".sqlite" in l]
    print("    store files:", stores)
    # The unsigned Debug build is not sandboxed, so Core Data ignores HOME and uses
    # ~/Library/Application Support/<app name>/ — a dev-only location no signed
    # build (sandboxed → ~/Library/Containers/…) ever touches. Accept that or the
    # fake HOME; refuse anything under Containers / Group Containers.
    allowed = (FAKE_HOME, DEV_STORE_DIR)
    if not stores or any(not f.startswith(allowed) or "/Containers/" in f for f in stores):
        raise SystemExit("ABORT: host store is not isolated: %r" % stores)
    ok(True, "A: Core Data store isolated (dev-only location, not the live archive)")
    B = Proc("B"); ok(B.init() is not None, "B: initialize")
    ok(B.wait_for("relay — headless", 20), "B: relay")
    C = Proc("C"); ok(C.init() is not None, "C: initialize")
    ok(C.wait_for("relay — headless", 20), "C: relay")
    tools_ok(B, "B via A"); cli_ok(C, "C via A")

    print("[phase 2] host A is SIGKILLed — relays must re-elect")
    if TRACE: TRACE.write(f"{time.strftime('%H:%M:%S')}.{int((time.time()%1)*1000):03d} [harness] SIGKILL A (pid {A.p.pid})\n")
    A.p.send_signal(signal.SIGKILL); A.p.wait()
    t0 = time.time()
    rB = tools_ok(B, "B after A died")
    rC = tools_ok(C, "C after A died")
    print(f"    (both served {time.time()-t0:.1f}s after the kill)")
    time.sleep(0.5)
    # Strict on hosting: a process that EVER hosted counts (two hosts, even
    # briefly, would mean two Core Data writers). Settled role for the relay.
    hosts  = [p for p in (B, C) if p.has("now hosts the engine")]
    relays = [p for p in (B, C) if p.final_role() == "relay"]
    ok(len(hosts) == 1 and len(relays) == 1,
       f"exactly one re-elected host ({[h.name for h in hosts]}) and one relay ({[r.name for r in relays]})")
    ok(all(p.alive() for p in (B, C)), "B and C both still alive")
    H, R = (hosts[0], relays[0]) if hosts and relays else (B, C)
    ok(H.has("serving locally") and H.has("after re-election"), f"{H.name}: took on the host GUI role after re-election")
    cli_ok(R, f"{R.name} via re-elected host {H.name}")

    print("[phase 3] new host's stdin closes while a peer remains — it must linger")
    H.close_stdin()
    ok(H.wait_for("lingering as host", 10), f"{H.name}: lingers for its peer")
    time.sleep(1.0)
    ok(H.alive(), f"{H.name}: still alive 1s after its stdin closed")
    tools_ok(R, f"{R.name} via lingering host")

    print("[phase 4] last peer leaves — lingering host exits")
    R.close_stdin()
    try: R.p.wait(timeout=15); ok(True, f"{R.name}: exited on stdin EOF")
    except subprocess.TimeoutExpired: ok(False, f"{R.name}: exited on stdin EOF")
    try: H.p.wait(timeout=15); ok(H.has("last peer session left"), f"{H.name}: lingering host terminated after the last peer left")
    except subprocess.TimeoutExpired: ok(False, f"{H.name}: lingering host terminated after the last peer left")
    sock = SOCK
    ok(not os.path.exists(sock), "socket file unlinked on clean exit")
finally:
    for p in [x for x in globals().values() if isinstance(x, Proc)]:
        if p.alive(): p.p.kill()
    time.sleep(0.5)
    shutil.rmtree(DEV_STORE_DIR, ignore_errors=True)   # leave nothing behind

print(f"\n{sum(results)} passed, {len(results)-sum(results)} failed")
sys.exit(0 if all(results) else 1)
