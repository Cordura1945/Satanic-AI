#!/usr/bin/env python3
"""Baut setup_all.sh aus setup_template.sh und den Dateien in chat/.

setup_all.sh ist ein kleines Start-Skript mit angehaengter, xz-gepackter Nutzlast.
Auf dem Pod entpackt es sich selbst nach setup_run.sh und fuehrt das aus.
Das haelt die Datenmenge klein, die die Starter-App beim Anlegen des Pods mitschickt.

Aufruf:
  python3 tools/build_setup.py          erzeugt setup_all.sh (macht der Build automatisch)
  python3 tools/build_setup.py --check  prueft nur: Syntax, Selbstentpacken, Groesse
"""
import base64, gzip, lzma, os, re, shutil, subprocess, sys, tempfile, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "setup_template.sh")
OUT = os.path.join(ROOT, "setup_all.sh")
# Die Starter-App schickt das Skript gzip+Base64-kodiert in der Anfrage an RunPod mit.
# Bis 97.200 Zeichen lief das nachweislich, bei 99.560 kam HTTP 500. Deshalb darunter bleiben.
LIMIT = 96000
LIC_MARK = "LICENSE_SERVER_PLACEHOLDER"
FULL = os.path.join(ROOT, "setup_full.sh")
KV_NAMESPACE = "c8cce7d941d0448e814116446000f406"  # Speicher LIC des Lizenz-Servers (license/wrangler.toml)

# Kleines Start-Skript: laedt das eigentliche Setup-Skript vom Lizenz-Server. Damit haengt der Pod-Start
# nicht mehr an der Groessengrenze. Scheitert das Laden, zeigt es der Starter-App eine Fehlermeldung an.
LOADER = r"""#!/bin/bash
# Satanic-AI Start: laedt das Setup-Skript vom Lizenz-Server und fuehrt es aus. Quelltext: tools/build_setup.py.
U="@@URL@@"; F="$(dirname "$0")/setup_full.sh"
PY=$(command -v python3 || command -v python)
"$PY" - "$U" "$F" <<'PYL' || exit 1
import json, os, sys, time, urllib.request, urllib.error
u, out = sys.argv[1], sys.argv[2]; err = "unbekannt"
for i in range(6):
    try:
        rq = urllib.request.Request(u, headers={"X-License": os.environ.get("LICENSE_KEY", ""), "User-Agent": "satanic-setup/1"})
        d = urllib.request.urlopen(rq, timeout=120).read()
        if d.startswith(b"#!/bin/bash") and len(d) > 2000:
            open(out, "wb").write(d); sys.exit(0)
        err = "unerwartete Antwort"
    except urllib.error.HTTPError as e:
        err = {400: "Lizenz-Key fehlt", 403: "Lizenz vom Server abgelehnt", 404: "Setup-Dateien fehlen auf dem Server"}.get(e.code, "HTTP %d" % e.code)
        if e.code in (400, 403, 404): break
    except Exception as e:
        err = type(e).__name__
    print("Setup-Dateien laden: Versuch %d fehlgeschlagen (%s)" % (i + 1, err), flush=True)
    time.sleep(5 * (i + 1))
msg = "FEHLER: Setup-Dateien konnten nicht geladen werden (%s). Pod beenden und neu starten." % err
print(msg, flush=True)
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(s, *a): pass
    def do_GET(s):
        b = json.dumps({"phase": "setup", "pct": 5, "label": "Fehler", "log": [msg]}).encode()
        s.send_response(200); s.send_header("Content-Type", "application/json"); s.send_header("Access-Control-Allow-Origin", "*")
        s.send_header("Content-Length", str(len(b))); s.end_headers(); s.wfile.write(b)
HTTPServer(("0.0.0.0", 8000), H).serve_forever()
PYL
exec bash "$F" "$@"
"""

BOOT = r'''#!/bin/bash
# Satanic-AI Setup, selbstentpackend. Quelltext: setup_template.sh und chat/ im Repo.
S="$0"; O="$(dirname "$S")/setup_run.sh"
L=$(grep -n -m1 '^__NUTZLAST__$' "$S" | cut -d: -f1)
tail -n +$((L + 1)) "$S" | base64 -d > "$O.xz"
rm -f "$O"
if command -v xz >/dev/null 2>&1; then xz -dc "$O.xz" > "$O" 2>/dev/null; fi
if [ ! -s "$O" ]; then
  PY=$(command -v python3 || command -v python)
  "$PY" -c 'import lzma,sys;sys.stdout.buffer.write(lzma.decompress(open(sys.argv[1],"rb").read()))' "$O.xz" > "$O"
fi
if [ ! -s "$O" ] || ! bash -n "$O"; then echo "FEHLER: Setup-Skript konnte nicht entpackt werden (weder xz noch python3 mit lzma vorhanden?)"; exit 1; fi
rm -f "$O.xz"
if [ -n "$SETUP_NUR_ENTPACKEN" ]; then exit 0; fi
exec bash "$O" "$@"
exit 1
__NUTZLAST__
'''


def read(path):
    with open(path, "rb") as f:
        return f.read().replace(b"\r\n", b"\n")


def build_real():
    """Das eigentliche Setup-Skript: Template mit den Dateien aus chat/ als Klartext."""
    text = read(TEMPLATE).decode("utf-8")
    used = []

    def sub(m):
        rel, delim = m.group(1), m.group(2)
        body = read(os.path.join(ROOT, rel)).decode("utf-8")
        if "\x00" in body or any(line == delim for line in body.split("\n")):
            raise SystemExit(f"FEHLER: {rel} laesst sich nicht einbetten (Nullbyte oder Zeile '{delim}')")
        used.append(rel)
        return body + ("" if body.endswith("\n") else "\n") + delim + "\n"

    out, n = re.subn(r"(?m)^@@EMBED:([A-Za-z0-9_./-]+)@@\n(EOF_[A-Z0-9]+)\n", sub, text)
    if not n:
        raise SystemExit("FEHLER: keine @@EMBED-Zeilen in setup_template.sh gefunden")
    return out.encode("utf-8"), used


def build():
    real, used = build_real()
    b = base64.b64encode(lzma.compress(real, preset=9 | lzma.PRESET_EXTREME)).decode()
    payload = "\n".join(b[i:i + 76] for i in range(0, len(b), 76)) + "\n"
    return (BOOT + payload).encode("utf-8"), real, used


def check(data, real):
    ok = True

    def say(good, msg):
        nonlocal ok
        ok = ok and good
        print(("OK     " if good else "FEHLER ") + msg)

    r = subprocess.run([sys.executable, "-c", "import sys; compile(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1], 'exec')",
                        os.path.join(ROOT, "chat", "server.py")], capture_output=True, text=True)
    say(r.returncode == 0, "chat/server.py Python-Syntax" + ("" if r.returncode == 0 else "\n" + r.stderr.strip()[-600:]))

    html = read(os.path.join(ROOT, "chat", "index.html")).decode("utf-8")
    scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
    node = shutil.which("node")
    if node:
        for i, sc in enumerate(scripts):
            with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
                f.write(sc)
            r = subprocess.run([node, "--check", f.name], capture_output=True, text=True)
            os.unlink(f.name)
            say(r.returncode == 0, f"chat/index.html Skript {i + 1} JavaScript-Syntax" + ("" if r.returncode == 0 else "\n" + r.stderr.strip()[-600:]))
    else:
        print("HINWEIS node fehlt, JavaScript-Syntax von chat/index.html nicht geprueft")
    say(html.count("<script>") == html.count("</script>") and "</html>" in html, "chat/index.html vollstaendig")

    bash = shutil.which("bash")
    if bash:
        r = subprocess.run([bash, "-n"], input=real, capture_output=True)
        say(r.returncode == 0, "Setup-Skript Shell-Syntax" + ("" if r.returncode == 0 else "\n" + r.stderr.decode("utf-8", "replace").strip()[-600:]))
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "setup_all.sh")
            with open(p, "wb") as f:
                f.write(data)
            r = subprocess.run([bash, p], capture_output=True, cwd=d, env=dict(os.environ, SETUP_NUR_ENTPACKEN="1"))
            got = open(os.path.join(d, "setup_run.sh"), "rb").read() if os.path.exists(os.path.join(d, "setup_run.sh")) else b""
            say(r.returncode == 0 and got == real, "setup_all.sh entpackt sich selbst korrekt" + ("" if got == real else "\n" + (r.stdout + r.stderr).decode("utf-8", "replace")[-400:]))
    marks = [n for n in ("KIStart.swift", "app.html") if os.path.isfile(os.path.join(ROOT, n)) and LIC_MARK not in read(os.path.join(ROOT, n)).decode("utf-8", "replace")]
    say(not marks, "Lizenz-Platzhalter in den Apps vorhanden" + ("" if not marks else " (fehlt in: " + ", ".join(marks) + "; die Adresse gehoert nur in license/config.json)"))
    smoke = os.path.join(ROOT, "tools", "smoke_test.py")
    if os.name != "nt" and os.path.isfile(smoke):
        try:
            r = subprocess.run([sys.executable, smoke], capture_output=True, text=True, timeout=240)
            rest = "\n".join(l for l in (r.stdout + r.stderr).split("\n") if l.strip() and not l.startswith("OK "))[-900:]
            say(r.returncode == 0, "Probelauf des Chat-Servers" + ("" if r.returncode == 0 else "\n" + rest))
        except subprocess.TimeoutExpired:
            say(False, "Probelauf des Chat-Servers (Zeitlimit ueberschritten)")
    size = len(base64.b64encode(gzip.compress(data, 9, mtime=0)))
    if license_server():
        ld = loader()
        if bash:
            r = subprocess.run([bash, "-n"], input=ld, capture_output=True)
            say(r.returncode == 0, "Start-Skript Shell-Syntax")
        lsize = len(base64.b64encode(gzip.compress(ld, 9, mtime=0)))
        say(lsize <= LIMIT, f"Groesse fuer den Pod-Start: {lsize} Zeichen (das Setup-Skript mit {size} Zeichen laedt der Pod vom Lizenz-Server, keine Groessengrenze mehr)")
    else:
        say(size <= LIMIT, f"Groesse fuer den Pod-Start: {size} von hoechstens {LIMIT} Zeichen")
    return ok


def setup_name():
    """Name, unter dem das Setup-Skript auf dem Lizenz-Server liegt: der Branch des Builds."""
    return re.sub(r"[^A-Za-z0-9._-]", "-", os.environ.get("GITHUB_REF_NAME", ""))[:80]


def remote():
    """Im Build (CI) mit Lizenz-Server: Die App schickt nur das kleine Start-Skript mit, der Pod laedt den Rest."""
    return bool(os.environ.get("CI") and license_server() and setup_name())


def loader():
    return LOADER.replace("@@URL@@", license_server() + "/setup/" + (setup_name() or "main")).encode("utf-8")


def upload():
    """Legt setup_full.sh im Speicher des Lizenz-Servers ab (Schluessel setup:<branch>) und liest es zur Kontrolle zurueck."""
    import json, urllib.request
    tok = os.environ.get("CLOUDFLARE_API_TOKEN", "")
    if not tok:
        raise SystemExit("FEHLER: GitHub-Secret CLOUDFLARE_API_TOKEN fehlt. Ohne es kann das Setup-Skript nicht auf dem Lizenz-Server abgelegt werden.")
    api = "https://api.cloudflare.com/client/v4"

    def call(method, path, body=None):
        hd = {"Authorization": "Bearer " + tok}
        if body is not None: hd["Content-Type"] = "application/octet-stream"
        rq = urllib.request.Request(api + path, data=body, method=method, headers=hd)
        try:
            return urllib.request.urlopen(rq, timeout=60).read()
        except urllib.error.HTTPError as e:
            raise SystemExit(f"FEHLER: Cloudflare {method} {path.split('/storage')[-1]}: HTTP {e.code} {e.read()[:300].decode('utf-8', 'replace')}")

    acc = os.environ.get("CLOUDFLARE_ACCOUNT_ID")
    if not acc:
        try:
            acc = json.loads(call("GET", "/accounts"))["result"][0]["id"]
        except (SystemExit, LookupError):
            acc = json.loads(call("GET", "/memberships"))["result"][0]["account"]["id"]
    data = read(FULL)
    path = f"/accounts/{acc}/storage/kv/namespaces/{KV_NAMESPACE}/values/setup:{setup_name()}"
    call("PUT", path, data)
    for i in range(6):
        if call("GET", path) == data:
            print(f"Setup-Skript auf dem Lizenz-Server abgelegt: setup:{setup_name()} ({len(data)} Bytes)")
            return
        import time; time.sleep(5)
    raise SystemExit("FEHLER: Das abgelegte Setup-Skript stimmt beim Zuruecklesen nicht ueberein.")


def license_server():
    """Adresse des Lizenz-Servers aus license/config.json, oder '' wenn die Pruefung aus ist."""
    try:
        import json
        srv = str(json.load(open(os.path.join(ROOT, "license", "config.json"), encoding="utf-8")).get("server") or "").strip().rstrip("/")
    except Exception:
        return ""
    return srv if re.fullmatch(r"https://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]*)?", srv) else ""


def apply_license():
    """Nur im Build (CI): setzt die Server-Adresse in die Apps ein. Lokal bleiben die Dateien unveraendert."""
    srv = license_server()
    if not os.environ.get("CI"):
        return
    for name in ("KIStart.swift", "app.html"):
        p = os.path.join(ROOT, name)
        s = read(p).decode("utf-8")
        if srv and LIC_MARK in s:
            with open(p, "wb") as f:
                f.write(s.replace(LIC_MARK, srv).encode("utf-8"))
    print("Lizenzpruefung: " + ("AN, Server " + srv if srv else "aus (keine Adresse in license/config.json)"))


if __name__ == "__main__":
    data, real, used = build()
    if "--check" in sys.argv:
        sys.exit(0 if check(data, real) else 1)
    with open(FULL, "wb") as f:
        f.write(data)
    if "--upload" in sys.argv:
        upload()
        sys.exit(0)
    if remote():
        data = loader()
    size = len(base64.b64encode(gzip.compress(data, 9, mtime=0)))
    if size > LIMIT:
        raise SystemExit(f"FEHLER: Setup-Skript ist mit {size} Zeichen zu gross fuer den Pod-Start (hoechstens {LIMIT}). Dateien in chat/ verkleinern.")
    with open(OUT, "wb") as f:
        f.write(data)
    apply_license()
    if remote():
        print(f"setup_all.sh erzeugt: kleines Start-Skript ({size} Zeichen), laedt setup:{setup_name()} vom Lizenz-Server. Volles Skript: setup_full.sh aus setup_template.sh + " + ", ".join(used))
    else:
        print(f"setup_all.sh erzeugt ({len(data)} Bytes, {size} Zeichen fuer den Pod-Start) aus setup_template.sh + " + ", ".join(used))
