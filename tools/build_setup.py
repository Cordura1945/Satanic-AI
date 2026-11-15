#!/usr/bin/env python3
"""Baut setup_all.sh aus setup_template.sh und den Dateien in chat/.

Aufruf:
  python3 tools/build_setup.py          erzeugt setup_all.sh (macht der Build automatisch)
  python3 tools/build_setup.py --check  prueft nur: Python-Syntax, JavaScript-Syntax, Shell-Syntax, Groesse
"""
import base64, gzip, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "setup_template.sh")
OUT = os.path.join(ROOT, "setup_all.sh")
LIMIT = 125000  # eine Umgebungsvariable darf unter Linux hoechstens 131072 Zeichen haben


def read(path):
    with open(path, "rb") as f:
        return f.read().replace(b"\r\n", b"\n")


def blob(path):
    b = base64.b64encode(gzip.compress(read(path), 9, mtime=0)).decode()
    return "\n".join(b[i:i + 76] for i in range(0, len(b), 76))


def build():
    text = read(TEMPLATE).decode("utf-8")
    used = []

    def sub(m):
        rel = m.group(1)
        used.append(rel)
        return blob(os.path.join(ROOT, rel))

    out = re.sub(r"(?m)^@@EMBED:([A-Za-z0-9_./-]+)@@$", sub, text)
    if not used:
        raise SystemExit("FEHLER: keine @@EMBED-Zeilen in setup_template.sh gefunden")
    return out.encode("utf-8"), used


def check(data):
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
        r = subprocess.run([bash, "-n"], input=data, capture_output=True)
        say(r.returncode == 0, "setup_all.sh Shell-Syntax" + ("" if r.returncode == 0 else "\n" + r.stderr.decode("utf-8", "replace").strip()[-600:]))
    size = len(base64.b64encode(gzip.compress(data, 9, mtime=0)))
    say(size <= LIMIT, f"Groesse fuer den Pod-Start: {size} von hoechstens {LIMIT} Zeichen")
    return ok


if __name__ == "__main__":
    data, used = build()
    if "--check" in sys.argv:
        sys.exit(0 if check(data) else 1)
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"setup_all.sh erzeugt ({len(data)} Bytes) aus setup_template.sh + " + ", ".join(used))
