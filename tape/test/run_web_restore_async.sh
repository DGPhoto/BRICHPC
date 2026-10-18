#!/bin/bash
# Review point #8: a web restore must not be killed after 120 s. It is now launched detached (SLURM if
# available, else a background process) and its progress is streamed to a per-job log that a status
# endpoint polls. This test drives the real launcher/status helpers from cluster/web/bric-web.py with a
# fake `bric` so it needs no tape backend: it asserts running -> done (rc 0) and running -> failed (rc N),
# and that a restore outlasting an HTTP request is not truncated.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Private copy of the web dir so BRIC = <copy>/cluster/bin/bric resolves to our fake CLI.
mkdir -p "$TMP/cluster/web" "$TMP/cluster/bin"
cp "$REPO/cluster/web/bric-web.py" "$TMP/cluster/web/bric-web.py"
cat > "$TMP/cluster/bin/bric" <<'FAKE'
#!/bin/bash
# Fake bric restore: emit a few progress lines over ~3s (longer than a snappy HTTP request), then exit
# with 0, or 3 if --dest mentions "fail". Proves the detached job is not bound to the request lifetime.
dest=""; while [ "$#" -gt 0 ]; do [ "$1" = --dest ] && dest="$2"; shift; done
echo "staging chunk 1 from tape"; sleep 1
echo "staging chunk 2 from tape"; sleep 1
echo "decrypt + verify"; sleep 1
case "$dest" in *fail*) echo "verify FAILED"; exit 3;; *) echo "restore complete and verified"; exit 0;; esac
FAKE
chmod +x "$TMP/cluster/bin/bric" 2>/dev/null || true

export HOME="$TMP/home"; mkdir -p "$HOME"
export PYTHONDONTWRITEBYTECODE=1

run_case() {  # dest  expect_state  expect_rc
    python3 - "$TMP/cluster/web/bric-web.py" "$1" "$2" "$3" <<'PY'
import sys, time, importlib.util
modpath, dest, exp_state, exp_rc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
spec = importlib.util.spec_from_file_location("bricweb", modpath)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
jobid, how = m.launch_restore_async(["restore", "--project", "P", "--dest", dest])
assert m.JOBID_RE.match(jobid), "bad jobid %r" % jobid
# Poll like the status page would. The fake runs ~3s; if the launcher were synchronous-with-120s it
# would still work, but the point is it returns immediately and we observe a RUNNING state first.
saw_running = False
deadline = time.time() + 20
st = {"state": "running"}
while time.time() < deadline:
    st = m.restore_status(jobid)
    if st["state"] == "running":
        saw_running = True
    if st["state"] in ("done", "failed"):
        break
    time.sleep(0.4)
assert saw_running, "never observed a RUNNING state (launch was not async)"
assert st["state"] == exp_state, "state=%s expected %s (log=%r)" % (st["state"], exp_state, st["log"])
assert str(st["rc"]) == exp_rc, "rc=%s expected %s" % (st["rc"], exp_rc)
assert "restore complete" in st["log"] or "verify FAILED" in st["log"], "log not captured: %r" % st["log"]
# Unknown / malformed job ids must be rejected, not leak files.
assert m.restore_status("../etc/passwd")["state"] == "unknown"
assert m.restore_status("restore_bogus")["state"] == "unknown"
print("  ok: %s -> state=%s rc=%s (via %s)" % (dest, st["state"], st["rc"], how))
PY
}

echo "== async restore: success path =="
run_case "$TMP/out_ok" done 0
echo "== async restore: failure path =="
run_case "$TMP/out_fail_here" failed 3
echo "== job id validation rejects traversal =="
echo "  ok: malformed/unknown job ids return state=unknown (checked above)"
echo "PASS run_web_restore_async"
