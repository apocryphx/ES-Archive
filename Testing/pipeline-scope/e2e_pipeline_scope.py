#!/usr/bin/env python3
"""Persona-scope drill: a pipeline stage that fetches on its own terms must
still be bounded to the connection's author.

Regression for the arc leak found 2026-10-11: arc's window fetch carries no
author clause and does not intersect with its input, so `… | arc` returned
every author's entries in the window. Read stages only lost them at the exit
backstops (the diagnostic said "arc → 8 hits" while 2 rendered), and write
stages (tag, untag) sit behind no backstop at all, so `… | arc | tag X` tagged
another author's entries. The executor now scopes every stage's result before
the diagnostic is emitted and before the next stage runs.

Runs the real MCP binary in an isolated fake HOME (own socket, own empty Core
Data store), author A hosting and author B relaying — the same two-process
shape as the re-election drill — and checks both the count and the write path.
"""
import json, os, queue, shutil, subprocess, sys, threading, time

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
        self.name = name
        self.p = subprocess.Popen(
            [APP, "--author", name, "-ESActivationMode", "0", "-ESShowMainWindowAtLaunch", "NO"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)
        self.out = queue.Queue(); self.err = []; self.nid = 0
        threading.Thread(target=self._pump_out, daemon=True).start()
        threading.Thread(target=self._pump_err, daemon=True).start()
    def _pump_out(self):
        for line in iter(self.p.stdout.readline, b""):
            self.out.put(line.decode("utf-8", "replace"))
    def _pump_err(self):
        for line in iter(self.p.stderr.readline, b""):
            self.err.append(line.decode("utf-8", "replace").rstrip())
    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode()); self.p.stdin.flush()
    def call(self, method, params=None, timeout=60):
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
    def tool(self, tool_name, **arguments):
        r = self.call("tools/call", {"name": tool_name, "arguments": arguments})
        text = ((r or {}).get("result", {}).get("content") or [{}])[0].get("text", "{}")
        try: return json.loads(text)
        except Exception: return {"_raw": text, "_rpc": r}
    def init(self):
        r = self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "e2e", "version": "0"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r
    def has(self, needle): return any(needle in s for s in self.err)
    def wait_for(self, needle, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.has(needle): return True
            time.sleep(0.05)
        return False
    def kill(self):
        try: self.p.kill()
        except Exception: pass

results = []
def ok(cond, name):
    results.append(bool(cond)); print(("  ✓ " if cond else "  ✗ ") + name, flush=True)

def stage_hits(resp, stage_prefix):
    """The hit count the diagnostic reported for the stage whose spelling
    starts with stage_prefix, e.g. '| arc' → 8 from '| arc --window 24h → 8 hits'."""
    for line in (resp.get("pipeline") or "").split("\n"):
        if line.strip().startswith(stage_prefix):
            tail = line.split("→")[-1].strip()
            try: return int(tail.split()[0])
            except Exception: return None
    return None

A = B = None
try:
    print("[phase 1] A hosts, B relays")
    A = Proc("A"); ok(A.init() is not None, "A: initialize")
    ok(A.wait_for("serving locally", 30), "A: hosts")
    lsof = subprocess.run(["lsof", "-Fn", "-p", str(A.p.pid)], capture_output=True, text=True).stdout
    stores = [l[1:] for l in lsof.splitlines() if l.startswith("n") and ".sqlite" in l]
    if not stores or any(not f.startswith((FAKE_HOME, DEV_STORE_DIR)) or "/Containers/" in f for f in stores):
        raise SystemExit("ABORT: host store is not isolated: %r" % stores)
    ok(True, "A: Core Data store isolated")
    B = Proc("B"); ok(B.init() is not None, "B: initialize")
    ok(B.wait_for("relay — headless", 20), "B: relays to A")

    print("[phase 2] both authors store entries within one arc window")
    for i in range(3):
        r = A.tool("archive_store", body=f"A entry {i}\nBody of A's entry {i}.",
                   summary=f"Author A's entry number {i}, stored by the scope drill.")
        ok(r.get("status") == "created", f"A: store entry {i}")
    r = B.tool("archive_store", body="B entry\nBody of B's only entry.",
               summary="Author B's single entry, stored by the scope drill.")
    ok(r.get("status") == "created", "B: store entry")

    print("[phase 3] arc stays inside the author's scope, and the diagnostic says so")
    expr = "sort recent | head 1 | arc --window 24h | wc"
    rb = B.tool("archive_cli", expression=expr)
    ok(rb.get("count") == 1, f"B: arc | wc renders 1 (got {rb.get('count')})")
    ok(stage_hits(rb, "| arc") == 1, f"B: arc diagnostic reports 1 hit (got {stage_hits(rb, '| arc')})")
    ok(stage_hits(rb, "| wc") == 1, f"B: wc diagnostic reports 1 hit (got {stage_hits(rb, '| wc')})")
    ra = A.tool("archive_cli", expression=expr)
    ok(ra.get("count") == 3, f"A: arc | wc renders 3 (got {ra.get('count')})")
    ok(stage_hits(ra, "| arc") == 3, f"A: arc diagnostic reports 3 hits (got {stage_hits(ra, '| arc')})")

    print("[phase 4] a write stage after arc cannot touch the other author's entries")
    rt = B.tool("archive_tags", mode="create", name="scope-drill", kind="session")
    ok(rt.get("status") in ("created", "already_exists"), f"B: tag created ({rt.get('status')})")
    rtag = B.tool("archive_cli", expression="sort recent | head 1 | arc --window 24h | tag scope-drill")
    ok("error" not in rtag, f"B: arc | tag runs ({rtag.get('message', 'ok')})")
    ok(stage_hits(rtag, "| tag") == 1, f"B: tag diagnostic reports 1 hit (got {stage_hits(rtag, '| tag')})")
    tb = B.tool("archive_tagged", tag="scope-drill")
    ok(tb.get("count") == 1, f"B: sees 1 tagged entry (got {tb.get('count')})")
    ta = A.tool("archive_tagged", tag="scope-drill")
    ok(ta.get("count") == 0, f"A: sees 0 tagged entries — none of A's were tagged (got {ta.get('count')})")
    print("[phase 5] recall rows carry an age, not an ISO stamp")
    # Two of A's entries share a title → an ambiguous response, whose rows
    # come from CDMemoryLookup's shared helper.
    r = A.tool("archive_store", body="A twin\nFirst twin.", summary="Author A's first twin entry for the scope drill.")
    ok(r.get("status") == "created", "A: store twin 1")
    r = A.tool("archive_store", body="A twin\nSecond twin.", summary="Author A's second twin entry for the scope drill.")
    ok(r.get("status") == "created", "A: store twin 2")
    amb = A.tool("archive_read", title="A twin")
    rows = amb.get("matches") or []
    ok(amb.get("status") == "ambiguous" and len(rows) == 2, f"A: read of a shared title is ambiguous with 2 rows ({amb.get('status')})")
    ok(all("age" in row and "dateCreated" not in row for row in rows), f"A: ambiguous rows carry age, not dateCreated ({[sorted(r.keys()) for r in rows]})")
    ok(all(row.get("age", "").startswith("created ") for row in rows), f"A: ages read 'created …' ({[r.get('age') for r in rows]})")
    # forgotten ranks by oldest dateAccessed and skips never-read entries, so
    # read one first; an ambiguous response is not an access.
    rd = A.tool("archive_read", title="A twin", index=0)
    ok(rd.get("title") == "A twin", f"A: read twin 0 ({rd.get('status', 'ok')})")
    disc = A.tool("archive_discover", mode="forgotten", limit=5)
    found = disc.get("results") if isinstance(disc.get("results"), list) else []
    ok(len(found) > 0, f"A: discover forgotten returns rows ({len(found)})")
    ok(all("T" not in str(row.get("lastAccessed", "")) for row in found),
       f"A: lastAccessed is an age or 'never', not ISO ({sorted(set(str(r.get('lastAccessed')) for r in found))})")
    print("[phase 6] an explicit arc anchor outside the author's scope reads as missing")
    foreign = B.tool("archive_cli", expression='arc --anchor-title "A entry 0" | wc')
    ok(foreign.get("error") == "apply_failed" and "no entry titled" in foreign.get("message", ""),
       f"B: arc --anchor-title on A's entry errors as not found ({foreign.get('error')}: {foreign.get('message')})")
    own = B.tool("archive_cli", expression='arc --anchor-title "B entry" | wc')
    # arc is the first stage here, so its diagnostic line carries no "| " prefix.
    ok(own.get("count") == 1 and stage_hits(own, "arc") == 1,
       f"B: arc --anchor-title on its own entry works (count {own.get('count')}, arc {stage_hits(own, 'arc')})")
finally:
    for p in (B, A):
        if p: p.kill()

passed = sum(results); total = len(results)
print(f"\n{passed}/{total} checks passed")
sys.exit(0 if passed == total else 1)
