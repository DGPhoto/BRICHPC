#!/usr/bin/env python3
"""
bric-web — interfaccia web minimale per utenti non tecnici di BRIC Archive 2.0.

Si lancia come job SLURM (vedi bric-web.sbatch) e si raggiunge via tunnel SSH, come il template
RStudio. Modello di sicurezza:
  - il processo gira con l'UID di chi lancia il job, quindi ogni comando `bric` eredita identità,
    permessi e CHIAVE PERSONALE dell'utente: niente login applicativo, una sessione per utente;
  - il tunnel SSH è il confine di rete; in più ogni URL porta un TOKEN di sessione casuale
    (capability URL) così, anche se qualcuno sulla LAN del cluster raggiunge la porta, senza il
    token riceve 403 (difesa in profondità sopra `--auth-none` di RStudio).

Dipendenze: solo la stdlib Python 3 (nessun pip). Tutte le mutazioni passano per la CLI `bric`
(subprocess con argv, MAI shell=True → niente shell-injection); il catalogo è letto in SOLA LETTURA.
"""
import html
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.parse
# ThreadingHTTPServer landed in Python 3.7; supekgate ships 3.6 (RHEL-family default). Build the
# exact equivalent when it is missing instead of requiring a newer interpreter on the cluster side.
try:
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
except ImportError:  # Python 3.6
    import socketserver
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class ThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
        daemon_threads = True

HERE = os.path.dirname(os.path.realpath(__file__))
BRIC = os.path.join(HERE, "..", "bin", "bric")
DB = os.environ.get("BRIC_DB") or os.path.join(HERE, "..", "db", "cluster_catalog.db")
USER = os.environ.get("BRIC_USER") or os.environ.get("USER") or "unknown"
TOKEN = os.environ.get("BRIC_WEB_TOKEN") or secrets.token_urlsafe(24)
ADDR = os.environ.get("BRIC_WEB_ADDR", "0.0.0.0")
PORT = int(os.environ.get("BRIC_WEB_PORT", os.environ.get("PORT", "8899")))
# Scadenza della SESSIONE = fine della walltime del job SLURM (epoch sec), calcolata dallo sbatch.
DEADLINE = int(os.environ.get("BRIC_WEB_DEADLINE", "0") or "0")
HOME = os.environ.get("HOME", "/home/%s" % USER)
# Punti di partenza del browser di cartelle (scorciatoie). La navigazione resta libera ma limitata dai
# permessi reali dell'uid dell'utente (il server gira come lui: non concede nulla che la shell non dia).
BROWSE_ROOTS = [p for p in os.environ.get("BRIC_WEB_BROWSE_ROOTS", "").split(":") if p] or \
               [p for p in [HOME, "/projects", "/datasets", "/home", "/"] if os.path.isdir(p)]
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")   # mirrors valid_name in lib_common.sh

STATUS_CLASS = {
    "CLOSED": "ok", "PRODUCING": "run", "RESERVED": "run", "PLANNING": "run",
    "DRAINING": "run", "CLOSING": "run", "FAILED": "bad", "DENIED": "bad", "CANCELLED": "bad",
}


def run_bric(args):
    """Run the bric CLI as the current user. Returns (rc, stdout+stderr). No shell."""
    try:
        p = subprocess.run([BRIC] + args, capture_output=True, text=True, timeout=120,
                           env=os.environ.copy())
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout: il comando ha impiegato troppo (l'archiviazione vera prosegue come job SLURM)."
    except Exception as e:  # noqa
        return 1, "errore nell'eseguire bric: %s" % e


# --- asynchronous restore -------------------------------------------------------------------------
# A restore stages chunks from tape, decrypts and verifies them; it can run far longer than an HTTP
# request. So instead of a synchronous (and 120 s-killable) subprocess.run, we launch it detached and
# stream its progress to a per-job log that a status page polls. Under SLURM the restore is submitted
# as a job (it survives the web session and runs on a node); otherwise it is a detached background
# process. Either way no user value is ever passed through a shell — argv only.
RESTORE_DIR = os.path.join(HOME, ".bric-web", "restores")
JOBID_RE = re.compile(r"^restore_[0-9TZ]+_[0-9a-f]{8}$")
EXIT_SENTINEL = "__BRIC_RESTORE_EXIT__"


def _restore_runner():
    """Write (once) a tiny argv-safe wrapper: $1=logfile, rest=command. Appends an exit sentinel."""
    os.makedirs(RESTORE_DIR, mode=0o700, exist_ok=True)
    runner = os.path.join(RESTORE_DIR, "_runner.sh")
    body = ('#!/bin/sh\n'
            'log="$1"; shift\n'
            '{ echo "=== restore started $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="; "$@"; '
            'echo "' + EXIT_SENTINEL + ' $?"; } >> "$log" 2>&1\n')
    tmp = runner + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.chmod(tmp, 0o700)
    os.replace(tmp, runner)
    return runner


def launch_restore_async(args):
    """Start `bric <args>` detached, logging to a per-job file. Returns (jobid, how)."""
    runner = _restore_runner()
    jobid = "restore_" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "_" + secrets.token_hex(4)
    log = os.path.join(RESTORE_DIR, jobid + ".log")
    open(log, "w").close()
    cmd = [runner, log, BRIC] + args
    env = os.environ.copy()
    if shutil.which("sbatch"):
        # Submit as a SLURM job so the restore outlives the web session and runs on a compute node.
        sb = ["sbatch", "--parsable", "-J", "bric-restore", "-o", "/dev/null", "-e", "/dev/null"] + cmd
        try:
            p = subprocess.run(sb, capture_output=True, text=True, timeout=30, env=env)
            if p.returncode == 0:
                return jobid, "slurm:" + (p.stdout or "").strip()
        except Exception:  # noqa  (fall back to detached)
            pass
    # No SLURM (or submit failed): detached background process, own session so it survives this thread.
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True, env=env)
    return jobid, "local"


def restore_status(jobid):
    """Return {state, rc, log} for a restore job. state: running | done | failed | unknown."""
    if not JOBID_RE.match(jobid or ""):
        return {"state": "unknown", "log": "", "rc": None}
    log = os.path.join(RESTORE_DIR, jobid + ".log")
    try:
        with open(log, "r", errors="replace") as f:
            data = f.read()
    except OSError:
        return {"state": "unknown", "log": "", "rc": None}
    state, rc = "running", None
    idx = data.rfind(EXIT_SENTINEL)
    if idx != -1:
        tail = data[idx + len(EXIT_SENTINEL):].strip().split()
        try:
            rc = int(tail[0]) if tail else None
        except ValueError:
            rc = None
        state = "done" if rc == 0 else "failed"
        data = data[:idx].rstrip()
    if len(data) > 16000:
        data = "…(troncato)…\n" + data[-16000:]
    return {"state": state, "rc": rc, "log": data}


def my_runs():
    """Read THIS user's runs from the catalog, read-only. Never writes the DB."""
    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=15)
        con.row_factory = sqlite3.Row
        rows = con.execute(
            "SELECT r.run_id, r.project_name, r.kind, r.status, r.n_chunks, r.total_bytes, "
            "r.requested_at, r.closed_at, r.error, "
            "(SELECT COUNT(*) FROM chunks c WHERE c.run_id=r.run_id AND c.state='DONE') AS done "
            "FROM runs r WHERE r.owner=? ORDER BY r.requested_at DESC LIMIT 50", (USER,)
        ).fetchall()
        con.close()
        return [dict(x) for x in rows]
    except Exception as e:  # noqa  (DB may not exist yet)
        return [{"_error": str(e)}]


def tib(n):
    try:
        return "%.2f TiB" % (int(n) / 1099511627776.0)
    except Exception:  # noqa
        return "?"


def remaining_seconds():
    """Secondi alla fine della walltime del job, o None se non noto (fuori da SLURM)."""
    if DEADLINE <= 0:
        return None
    import time
    return max(0, DEADLINE - int(time.time()))


def list_dir(path):
    """Lista le SOTTOcartelle di `path` (per il folder-picker). I permessi sono quelli dell'uid utente."""
    try:
        real = os.path.realpath(path or HOME)
    except Exception:  # noqa
        real = HOME
    if not os.path.isdir(real):
        return {"error": "Non è una cartella: %s" % real}
    if not os.access(real, os.R_OK | os.X_OK):
        return {"error": "Permesso negato: %s" % real}
    dirs, nfiles = [], 0
    try:
        with os.scandir(real) as it:
            for e in it:
                if e.name.startswith("."):
                    continue
                try:
                    if e.is_dir(follow_symlinks=True):
                        dirs.append(e.name)
                    else:
                        nfiles += 1
                except OSError:
                    continue
    except PermissionError:
        return {"error": "Permesso negato: %s" % real}
    dirs.sort(key=str.lower)
    parent = os.path.dirname(real.rstrip("/")) or "/"
    return {"path": real, "parent": parent if real != "/" else None,
            "dirs": dirs, "n_files": nfiles, "roots": BROWSE_ROOTS}


# ---------------------------------------------------------------------------- HTML

CSS = """
:root{--fg:#1a1a1a;--mut:#666;--line:#e2e2e2;--ok:#0a7d32;--run:#9a6700;--bad:#b42318;--acc:#1f5fa8}
*{box-sizing:border-box}body{font:15px/1.5 system-ui,sans-serif;color:var(--fg);margin:0;background:#fafafa}
header{background:#fff;border-bottom:1px solid var(--line);padding:14px 22px;display:flex;align-items:baseline;gap:14px}
header h1{font-size:18px;margin:0}header .who{color:var(--mut);font-size:13px}
main{max-width:980px;margin:22px auto;padding:0 18px;display:grid;gap:22px}
.card{background:#fff;border:1px solid var(--line);border-radius:10px;padding:18px}
.card h2{font-size:15px;margin:0 0 12px}
label{display:block;font-size:13px;color:var(--mut);margin:10px 0 4px}
input[type=text]{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:7px;font:inherit}
button{background:var(--acc);color:#fff;border:0;border-radius:7px;padding:9px 16px;font:inherit;cursor:pointer;margin-top:12px}
button.sec{background:#fff;color:var(--acc);border:1px solid var(--acc)}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line)}
th{color:var(--mut);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.03em}
.badge{font-size:12px;font-weight:600;padding:2px 9px;border-radius:20px;background:#eee}
.badge.ok{background:#e7f6ec;color:var(--ok)}.badge.run{background:#fdf4e3;color:var(--run)}.badge.bad{background:#fdeceb;color:var(--bad)}
.bar{height:6px;background:#eee;border-radius:4px;overflow:hidden;margin-top:4px}.bar>i{display:block;height:100%;background:var(--acc)}
.msg{padding:12px 14px;border-radius:8px;margin:0 0 14px;font-size:14px;white-space:pre-wrap}
.msg.ok{background:#e7f6ec;color:#075d25}.msg.bad{background:#fdeceb;color:#8a1c14}
.hint{color:var(--mut);font-size:12px;margin-top:4px}.mono{font-family:ui-monospace,monospace;font-size:12px}
.sess{margin-left:auto;font-size:13px;color:var(--mut)}.sess b{color:var(--fg);font-variant-numeric:tabular-nums}
.sess.warn b{color:var(--bad)}
.row{display:flex;gap:8px;align-items:stretch}.row input{flex:1}
.browse{background:#fff;color:var(--acc);border:1px solid var(--acc);border-radius:7px;padding:0 12px;margin-top:0;cursor:pointer;white-space:nowrap}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.4);display:none;align-items:center;justify-content:center;z-index:9}
.modal.open{display:flex}
.dialog{background:#fff;border-radius:12px;width:min(620px,92vw);max-height:82vh;display:flex;flex-direction:column;overflow:hidden}
.dialog header{display:block;border-bottom:1px solid var(--line);padding:14px 18px}
.dialog h3{margin:0;font-size:15px}.crumb{font-size:12px;color:var(--mut);margin-top:4px;word-break:break-all}
.roots{display:flex;gap:6px;flex-wrap:wrap;padding:10px 18px;border-bottom:1px solid var(--line)}
.chip{font-size:12px;border:1px solid var(--line);border-radius:20px;padding:3px 11px;background:#fafafa;cursor:pointer}
.flist{overflow:auto;padding:6px 10px}.flist .it{display:flex;align-items:center;gap:9px;padding:8px 10px;border-radius:7px;cursor:pointer}
.flist .it:hover{background:#f3f6fb}.flist .it .ic{opacity:.7}
.dialog footer{display:flex;gap:10px;justify-content:space-between;align-items:center;padding:12px 18px;border-top:1px solid var(--line)}
.dialog .cur{font-size:12px;color:var(--mut);font-family:ui-monospace,monospace;word-break:break-all}
footer{max-width:980px;margin:10px auto 40px;padding:0 18px;color:var(--mut);font-size:12px}
"""

JS = """
async function refresh(){
  try{
    const r = await fetch(BASE+'/api/runs'); if(!r.ok) return;
    const runs = await r.json(); const tb = document.getElementById('runs'); if(!tb) return;
    tb.innerHTML = runs.length ? runs.map(rowHtml).join('') :
      '<tr><td colspan="5" style="color:#666">Nessun backup ancora. Usane uno qui sopra.</td></tr>';
  }catch(e){}
}
function rowHtml(x){
  const cls = x.cls||'', pct = x.n_chunks>0 ? Math.round(100*x.done/x.n_chunks):0;
  return `<tr><td><div>${esc(x.project_name)}</div><div class="mono">${esc(x.run_id)}</div></td>`+
    `<td><span class="badge ${cls}">${esc(x.status)}</span>${x.error?`<div class="hint">${esc(x.error)}</div>`:''}</td>`+
    `<td>${x.done}/${x.n_chunks}<div class="bar"><i style="width:${pct}%"></i></div></td>`+
    `<td>${esc(x.tib)}</td><td class="mono">${esc(x.requested_at||'')}</td></tr>`;
}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
setInterval(refresh, 8000);

// ---- countdown della sessione (walltime del job) ----
let LEFT = (typeof REMAINING==='number') ? REMAINING : null;
function fmt(s){const h=Math.floor(s/3600),m=Math.floor((s%3600)/60),x=s%60;
  return h>0 ? `${h}h ${String(m).padStart(2,'0')}m` : `${m}m ${String(x).padStart(2,'0')}s`;}
function tick(){const el=document.getElementById('sess'); if(!el||LEFT==null) return;
  if(LEFT<=0){el.innerHTML='sessione <b>scaduta</b> — rilancia il job';el.classList.add('warn');return;}
  el.querySelector('b').textContent=fmt(LEFT); el.classList.toggle('warn', LEFT<1800); LEFT--;}
if(LEFT!=null){tick();setInterval(tick,1000);}

// ---- browser di cartelle (folder picker) ----
let BTARGET=null;   // id dell'input da riempire
function openBrowse(targetId){BTARGET=targetId;document.getElementById('modal').classList.add('open');
  const v=document.getElementById(targetId).value; ls(v && v.startsWith('/') ? v : null);}
function closeBrowse(){document.getElementById('modal').classList.remove('open');}
async function ls(path){
  const u=BASE+'/api/ls'+(path?('?path='+encodeURIComponent(path)):'');
  let d; try{d=await (await fetch(u)).json();}catch(e){return;}
  const dlg=document.getElementById('dlg');
  if(d.error){dlg.querySelector('.flist').innerHTML='<div class="hint" style="padding:12px">'+esc(d.error)+'</div>';return;}
  document.getElementById('crumb').textContent=d.path;
  document.getElementById('cur').textContent=d.path;
  document.getElementById('cur').dataset.path=d.path;
  document.getElementById('roots').innerHTML=(d.roots||[]).map(r=>`<span class="chip" onclick="ls('${esc(r)}')">${esc(r)}</span>`).join('');
  let html='';
  if(d.parent) html+=`<div class="it" onclick="ls('${esc(d.parent)}')"><span class="ic">↰</span> .. (su)</div>`;
  html+=(d.dirs||[]).map(name=>`<div class="it" onclick="ls('${esc(d.path.replace(/\\/$/,'')+'/'+name)}')"><span class="ic">📁</span> ${esc(name)}</div>`).join('');
  if(!d.dirs||!d.dirs.length) html+=`<div class="hint" style="padding:10px">Nessuna sottocartella. ${d.n_files} file qui.</div>`;
  dlg.querySelector('.flist').innerHTML=html;
}
function chooseDir(){const p=document.getElementById('cur').dataset.path;
  if(BTARGET&&p){document.getElementById(BTARGET).value=p;} closeBrowse();}
"""


def page(body, msg=None, base=""):
    m = ""
    if msg:
        cls, text = msg
        m = '<div class="msg %s">%s</div>' % (cls, html.escape(text))
    rem = remaining_seconds()
    sess = ('<span class="sess" id="sess">sessione: <b>—</b> rimaste</span>' if rem is not None else "")
    modal = ("""
<div class="modal" id="modal"><div class="dialog" id="dlg">
  <header><h3>Scegli una cartella</h3><div class="crumb" id="crumb"></div></header>
  <div class="roots" id="roots"></div>
  <div class="flist"></div>
  <footer><span class="cur" id="cur" data-path=""></span>
    <span><button class="sec" type="button" onclick="closeBrowse()">Annulla</button>
    <button type="button" onclick="chooseDir()">Scegli questa cartella</button></span></footer>
</div></div>""")
    return ("<!doctype html><html lang=it><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>BRIC Archive</title><style>%s</style></head><body>"
            "<header><h1>BRIC Archive</h1><span class=who>utente: <b>%s</b></span>%s</header>"
            "<main>%s%s</main>%s"
            "<footer>Sessione personale (uid %s). I dati vengono cifrati con la tua chiave prima di "
            "lasciare il cluster. L'archiviazione vera prosegue come job SLURM anche se chiudi questa "
            "pagina.</footer>"
            "<script>const BASE=%s;const REMAINING=%s;%s;refresh();</script></body></html>"
            ) % (CSS, html.escape(USER), sess, m, body, modal, html.escape(USER),
                 json.dumps(base), ("null" if rem is None else str(rem)), JS)


def runs_table_rows(runs):
    if runs and runs[0].get("_error"):
        return '<tr><td colspan="5" class="hint">Catalogo non ancora leggibile: %s</td></tr>' % html.escape(runs[0]["_error"])
    if not runs:
        return '<tr><td colspan="5" class="hint">Nessun backup ancora. Usane uno qui sopra.</td></tr>'
    out = []
    for x in runs:
        cls = STATUS_CLASS.get(x["status"], "")
        pct = round(100 * x["done"] / x["n_chunks"]) if x["n_chunks"] else 0
        err = '<div class="hint">%s</div>' % html.escape(x["error"]) if x.get("error") else ""
        out.append(
            '<tr><td><div>%s</div><div class="mono">%s</div></td>'
            '<td><span class="badge %s">%s</span>%s</td>'
            '<td>%d/%d<div class="bar"><i style="width:%d%%"></i></div></td>'
            '<td>%s</td><td class="mono">%s</td></tr>' % (
                html.escape(x["project_name"]), html.escape(x["run_id"]), cls,
                html.escape(x["status"]), err, x["done"], x["n_chunks"], pct,
                tib(x["total_bytes"]), html.escape(x.get("requested_at") or ""))
        )
    return "".join(out)


def dashboard(base, msg=None):
    runs = my_runs()
    body = """
<div class="card">
  <h2>Nuovo backup</h2>
  <form method=post action="%(b)s/backup">
    <label for=p>Nome progetto</label>
    <input id=p type=text name=project placeholder="es. mouse_rnaseq" required>
    <label for=s>Cartella da archiviare (percorso sul cluster)</label>
    <div class=row><input id=s type=text name=source placeholder="/projects/.../mouse_rnaseq" required>
      <button class=browse type=button onclick="openBrowse('s')">Sfoglia…</button></div>
    <div class=hint>La cartella deve esistere ed essere leggibile da te. Verrà cifrata con la tua chiave.</div>
    <button type=submit>Avvia backup</button>
  </form>
</div>
<div class="card">
  <h2>Ripristino</h2>
  <form method=post action="%(b)s/restore">
    <label for=rp>Progetto da ripristinare</label>
    <input id=rp type=text name=project placeholder="es. mouse_rnaseq" required>
    <label for=rd>Cartella di destinazione</label>
    <div class=row><input id=rd type=text name=dest value="%(home)s/bric-restore" required>
      <button class=browse type=button onclick="openBrowse('rd')">Sfoglia…</button></div>
    <div class=hint>Opzionale: lascia vuoto il file per ripristinare tutto il progetto.</div>
    <label for=rf>Singolo file (opzionale, percorso relativo)</label>
    <input id=rf type=text name=file placeholder="(vuoto = tutto il progetto)">
    <button class=sec type=submit>Ripristina</button>
  </form>
</div>
<div class="card">
  <h2>I miei backup</h2>
  <table><thead><tr><th>Progetto / run</th><th>Stato</th><th>Avanzamento</th><th>Dimensione</th><th>Richiesto</th></tr></thead>
  <tbody id=runs>%(rows)s</tbody></table>
</div>
""" % {"b": base, "home": html.escape(os.environ.get("HOME", "/home/%s" % USER)),
       "rows": runs_table_rows(runs)}
    return page(body, msg=msg, base=base)


def restore_status_page(jobid, project, dest, base):
    body = """
<div class="card">
  <h2>Ripristino in corso</h2>
  <div class="hint">Progetto <b>@@PROJECT@@</b> → <span class="mono">@@DEST@@</span></div>
  <div class="hint">Job: <span class="mono">@@JOBID@@</span></div>
  <p id="st" class="msg run">Avvio del ripristino…</p>
  <div class="hint">Il ripristino prosegue anche se chiudi questa pagina; puoi tornare qui o usare
    <span class="mono">bric restore</span> dalla shell. Questa pagina si aggiorna da sola.</div>
  <pre id="log" class="mono" style="white-space:pre-wrap;max-height:50vh;overflow:auto;background:#0b1020;color:#cbd5e1;padding:12px;border-radius:10px;margin-top:12px"></pre>
  <p><a href="@@BASE@@/">← torna alla dashboard</a></p>
</div>
<script>
const JOB="@@JOBID@@", API="@@BASE@@/api/restore-status?job="+encodeURIComponent(JOB);
const st=document.getElementById('st'), lg=document.getElementById('log');
async function poll(){
  let d; try{ d=await (await fetch(API)).json(); }catch(e){ return; }
  lg.textContent=d.log||''; lg.scrollTop=lg.scrollHeight;
  if(d.state==='done'){ st.textContent='✓ Ripristino completato e verificato.'; st.className='msg ok'; return; }
  if(d.state==='failed'){ st.textContent='✗ Ripristino fallito'+(d.rc!=null?(' (codice '+d.rc+')'):'')+'. Vedi il log qui sotto.'; st.className='msg bad'; return; }
  if(d.state==='unknown'){ st.textContent='Job non trovato o non ancora avviato…'; }
  else { st.textContent='⏳ Ripristino in corso… (staging da nastro, decifratura, verifica)'; }
  setTimeout(poll, 3000);
}
poll();
</script>
"""
    body = (body.replace("@@PROJECT@@", html.escape(project))
                .replace("@@DEST@@", html.escape(dest))
                .replace("@@JOBID@@", html.escape(jobid))
                .replace("@@BASE@@", base))
    return page(body, base=base)


# ---------------------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "bric-web"

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(b)

    def _auth(self):
        """Path must start with /<TOKEN>/. Returns the remaining path, or None -> 403."""
        parts = urllib.parse.urlsplit(self.path)
        segs = parts.path.split("/", 2)   # ['', token, rest]
        if len(segs) >= 2 and secrets.compare_digest(segs[1], TOKEN):
            return "/" + (segs[2] if len(segs) > 2 else "")
        return None

    def log_message(self, *a):  # quieter logs (no data values)
        sys.stderr.write("%s - %s\n" % (self.address_string(), a[0] % a[1:]))

    def do_GET(self):
        rest = self._auth()
        if rest is None:
            return self._send(403, page('<div class="card">Token di sessione mancante o errato. '
                                        'Usa il link completo stampato nel log del job.</div>'))
        base = "/" + TOKEN
        if rest in ("/", ""):
            return self._send(200, dashboard(base))
        if rest == "/api/runs":
            runs = my_runs()
            for x in runs:
                x["cls"] = STATUS_CLASS.get(x.get("status"), "")
                x["tib"] = tib(x.get("total_bytes"))
            return self._send(200, json.dumps(runs), "application/json")
        if rest == "/api/ls":
            qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            path = (qs.get("path", [""])[0] or "").strip() or HOME
            return self._send(200, json.dumps(list_dir(path)), "application/json")
        if rest == "/api/restore-status":
            qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            return self._send(200, json.dumps(restore_status((qs.get("job", [""])[0] or "").strip())),
                              "application/json")
        if rest == "/restore-status":
            qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            jobid = (qs.get("job", [""])[0] or "").strip()
            if not JOBID_RE.match(jobid):
                return self._send(200, dashboard(base, ("bad", "Job di ripristino non valido.")))
            proj = (qs.get("project", [""])[0] or "").strip()
            dest = (qs.get("dest", [""])[0] or "").strip()
            return self._send(200, restore_status_page(jobid, proj, dest, base))
        return self._send(404, page('<div class="card">Pagina non trovata.</div>', base=base))

    def do_POST(self):
        rest = self._auth()
        if rest is None:
            return self._send(403, page('<div class="card">Token mancante o errato.</div>'))
        base = "/" + TOKEN
        length = int(self.headers.get("Content-Length", "0") or "0")
        data = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8")) if length else {}

        def field(k):
            return (data.get(k, [""])[0] or "").strip()

        if rest == "/backup":
            project, source = field("project"), field("source")
            if not NAME_RE.match(project):
                return self._send(200, dashboard(base, ("bad", "Nome progetto non valido (lettere, numeri, . _ -).")))
            if not (os.path.isdir(source) and os.access(source, os.R_OK)):
                return self._send(200, dashboard(base, ("bad", "La cartella sorgente non esiste o non è leggibile:\n%s" % source)))
            rc, out = run_bric(["backup", "--project", project, "--source", source])
            cls = "ok" if rc == 0 else "bad"
            head = "Backup avviato.\n" if rc == 0 else "Il backup non è partito.\n"
            return self._send(200, dashboard(base, (cls, head + out.strip())))

        if rest == "/restore":
            project, dest, rfile = field("project"), field("dest"), field("file")
            if not NAME_RE.match(project):
                return self._send(200, dashboard(base, ("bad", "Nome progetto non valido.")))
            parent = os.path.dirname(os.path.abspath(dest)) or "/"
            if not dest or not (os.path.isdir(parent) and os.access(parent, os.W_OK)):
                return self._send(200, dashboard(base, ("bad", "Destinazione non scrivibile (la cartella superiore deve esistere):\n%s" % dest)))
            args = ["restore", "--project", project, "--dest", dest]
            if rfile:
                args += ["--file", rfile]
            # A restore can run far longer than an HTTP request (staging from tape + decrypt + verify),
            # so launch it detached and show a live status page instead of blocking/timing out at 120 s.
            jobid, how = launch_restore_async(args)
            q = urllib.parse.urlencode({"job": jobid, "project": project, "dest": dest})
            self.send_response(303)
            self.send_header("Location", "%s/restore-status?%s" % (base, q))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        return self._send(404, page('<div class="card">Azione sconosciuta.</div>', base=base))


def main():
    if not os.path.exists(BRIC):
        sys.stderr.write("ATTENZIONE: CLI bric non trovata in %s\n" % BRIC)
    httpd = ThreadingHTTPServer((ADDR, PORT), Handler)
    url = "http://localhost:8787/%s/" % TOKEN
    sys.stderr.write(
        "\n================ BRIC Archive — interfaccia web ================\n"
        "  utente:   %s\n  bind:     %s:%d\n  TOKEN:    %s\n"
        "  Apri (dopo il tunnel SSH):\n    %s\n"
        "===============================================================\n\n"
        % (USER, ADDR, PORT, TOKEN, url))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
