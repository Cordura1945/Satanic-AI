#!/usr/bin/env python3
"""Einzeltests fuer chat/server.py: edit_file/read_file, Kuerzen des Verlaufs, Dev-Server-Werkzeuge, Bildabgleich.

Aufruf:  python3 tools/unit_test.py     (Rueckgabe 0 = alles in Ordnung)
Die Bild-Tests brauchen Pillow und numpy (auf dem Pod vorhanden); fehlen sie, werden sie uebersprungen.
"""
import importlib.util, io, json, os, random, shutil, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = []


def say(ok, what, extra=""):
    results.append(ok)
    print(("OK     " if ok else "FEHLER ") + what + (("\n" + str(extra)) if (extra and not ok) else ""))


def load(tmp):
    os.environ.update({"STORE": os.path.join(tmp, "store"), "PROJECTS": os.path.join(tmp, "projects"), "AGENT_USER": "__keiner__",
                       "IDLE_STOP_MIN": "0"})
    for k in ("DEV_SERVER", "IMG_SERVER", "RUNPOD_POD_ID"): os.environ.pop(k, None)
    spec = importlib.util.spec_from_file_location("satanic_server", os.path.join(ROOT, "chat", "server.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def fails(fn):
    try: fn(); return None
    except Exception as e: return str(e)


def test_edit(S, proj):
    p = os.path.join(proj, "demo", "a.py"); os.makedirs(os.path.dirname(p), exist_ok=True)
    put = lambda t: open(p, "w").write(t)
    get = lambda: open(p).read()
    put("def a():\n    return 1\n\ndef b():\n    return 2\n")
    S.t_edit({"path": "demo/a.py", "old": "    return 1", "new": "    return 10"}, {})
    say("return 10" in get(), "edit_file: exakter Treffer")
    # Zeilennummern aus read_file mitkopiert
    r = S.t_edit({"path": "demo/a.py", "old": "4\tdef b():\n5\t    return 2", "new": "4\tdef b():\n5\t    return 20"}, {})
    say(get() == "def a():\n    return 10\n\ndef b():\n    return 20\n" and "Zeilennummern" in r, "edit_file: mitkopierte Zeilennummern werden entfernt", get())
    # Leerzeichen am Zeilenende in der Datei
    put("x = 1   \ny = 2\n")
    r = S.t_edit({"path": "demo/a.py", "old": "x = 1\ny = 2", "new": "x = 1\ny = 3"}, {})
    say(get() == "x = 1\ny = 3\n" and "Leerzeichen" in r, "edit_file: Leerzeichen am Zeilenende werden toleriert", get())
    # mehrdeutig bleibt ein Fehler, Einrueckung wird NICHT geraten
    put("a  \nb\na \nb\n    c\n")
    say("2-mal" in (fails(lambda: S.t_edit({"path": "demo/a.py", "old": "a\nb", "new": "z"}, {})) or ""), "edit_file: mehrdeutiger Treffer wird abgelehnt")
    say(fails(lambda: S.t_edit({"path": "demo/a.py", "old": "b\n  c", "new": "q"}, {})) is not None, "edit_file: falsche Einrueckung wird nicht erraten")
    # gekuerzte Zeile aus read_file
    put("k = '" + "x" * 3000 + "'\nende\n")
    shown = S.t_read({"path": "demo/a.py"}, {})
    say("Zeile gekuerzt, insgesamt 3006 Zeichen" in shown, "read_file: lange Zeile wird sichtbar als gekuerzt markiert", shown[:200])
    line = shown.split("\n")[0].split("\t", 1)[1]
    err = fails(lambda: S.t_edit({"path": "demo/a.py", "old": line, "new": "k = 1"}, {}))
    say(err is not None and "gekuerzt" in err, "edit_file: gekuerzte Zeile als old wird mit Hinweis abgelehnt", err)


def test_compact(S):
    msgs = [{"role": "system", "content": "s"}]
    for i in range(40):
        msgs.append({"role": "assistant", "content": None, "tool_calls": [{"id": "c%d" % i, "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]})
        msgs.append({"role": "tool", "tool_call_id": "c%d" % i, "content": "x" * 2000})
    S.compact(msgs)
    total = sum(len(m.get("content") or "") for m in msgs)
    say(total <= 60000 * 0.65, "Verlauf wird bei Ueberlauf kraeftig gekuerzt (unter 65 %)", total)
    snap = json.dumps(msgs)
    msgs.append({"role": "tool", "tool_call_id": "neu", "content": "y" * 2000})
    S.compact(msgs)
    say(json.dumps(msgs[:-1]) == snap, "danach bleibt der Anfang des Verlaufs unveraendert (Prompt-Cache bleibt nutzbar)")


def test_devserver(S):
    seen = {}
    def fake(messages, emit, fast=False, tools=True, think=False, temp=0.7, tool_list=None, stats=None):
        seen["sys"] = messages[0]["content"]; seen["tools"] = [t["function"]["name"] for t in (tool_list or [])]; seen["temp"] = temp
        return "ok", []
    S.llm_stream = fake
    cfg = {"repo": "", "token": ""}
    for devsrv in (False, True):
        S.DEVSRV = devsrv
        S.chat([{"role": "user", "text": "Hallo", "images": []}], lambda ev: None, dev=dict(cfg))
        names = set(seen["tools"])
        if devsrv:
            say("generate_image" not in names and "edit_image" not in names and "write_file" in names and "create_file" in names
                and "BILD-PROMPTS" not in seen["sys"] and "DEV-MODUS" in seen["sys"], "Dev-Server: ohne Bildteil und Bildwerkzeuge", seen)
        else:
            say("generate_image" in names and "write_file" in names and "BILD-PROMPTS" in seen["sys"], "normaler Server: Bildwerkzeuge bleiben", seen)
        say(seen["temp"] == 0.7, "Dev-Modus laeuft mit Temperatur 0.7" + (" (Dev-Server)" if devsrv else ""), seen["temp"])
    S.DEVSRV = False


def test_dev_loop(S, proj):
    """Werkzeug-Aufrufe pruefen, Sofortpruefung, mehrere Aenderungen, Auto-Weiter, Build-Warten."""
    # 1) kaputte oder unvollstaendige Aufrufe werden nicht ausgefuehrt
    a, e = S.call_check({"name": "write_file", "args": '{"path": "demo/x.py", "content": "abc'})
    say(e and "kein gueltiges JSON" in e, "kaputte Werkzeug-Angaben werden gemeldet", e)
    a, e = S.call_check({"name": "write_file", "args": '{"path": "demo/x.py"}'})
    say(e and "content" in e, "fehlende Pflichtangabe wird gemeldet", e)
    a, e = S.call_check({"name": "write_file", "args": '{"path": "demo/x.py", "content": "x"}'}, "length")
    say(e and "abgeschnitten" in e, "an der Laengengrenze abgeschnittener Aufruf wird gemeldet", e)
    a, e = S.call_check({"name": "zauber", "args": "{}"})
    say(e and "gibt es nicht" in e, "unbekanntes Werkzeug wird gemeldet", e)
    a, e = S.call_check({"name": "edit_file", "args": '{"path": "demo/x.py", "old": "a", "new": ""}'})
    say(e is None, "gueltiger Aufruf (auch mit leerem new) geht durch", e)

    # im Ablauf: kaputter write_file schreibt nichts, Verlauf bekommt "{}" statt der kaputten Angaben
    calls = [[{"id": "c1", "name": "write_file", "args": '{"path": "demo/kaputt.py", "content": "pri'}], []]
    hist = []
    def fake(messages, emit, fast=False, tools=True, think=False, temp=0.7, tool_list=None, stats=None):
        hist.append(json.loads(json.dumps(messages)))
        if stats is not None: stats["t"] = {"prompt_n": 120, "prompt_ms": 400, "cache_n": 3000, "predicted_n": 50, "predicted_ms": 900}
        return "", calls.pop(0) if calls else []
    S.llm_stream = fake; evs = []
    S.chat([{"role": "user", "text": "los", "images": []}], evs.append, dev={"repo": "", "token": ""})
    last = hist[-1]; tc = [m for m in last if m.get("role") == "assistant" and m.get("tool_calls")][0]["tool_calls"][0]
    res = [m for m in last if m.get("role") == "tool"][0]["content"]
    say(not os.path.exists(os.path.join(proj, "demo", "kaputt.py")) and tc["function"]["arguments"] == "{}" and res.startswith("FEHLER"),
        "Ablauf: kaputter write_file schreibt nichts und vergiftet den Verlauf nicht", res[:200])
    say(any(ev.get("type") == "stat" and "eingelesen 120 Tokens" in ev.get("text", "") and "3000 aus Zwischenspeicher" in ev.get("text", "") for ev in evs),
        "Zeitmessung pro Schritt wird angezeigt", [ev for ev in evs if ev.get("type") == "stat"][:2])

    # 2) Sofortpruefung nach write_file/edit_file
    S.SHELL_OK = True
    r = S.t_write({"path": "demo/ok.py", "content": "x = 1\n"}, {})
    say("Sofortpruefung: OK" in r, "Sofortpruefung: fehlerfreie Datei", r)
    r = S.t_write({"path": "demo/bad.py", "content": "def f(:\n"}, {})
    say("Sofortpruefung: FEHLER" in r and "bad.py" in r, "Sofortpruefung: Syntaxfehler wird sofort gemeldet", r)
    r = S.t_write({"path": "demo/bad.json", "content": "{\"a\": }"}, {})
    say("Sofortpruefung: FEHLER" in r, "Sofortpruefung: kaputtes JSON wird sofort gemeldet", r)

    # 3) mehrere Aenderungen in einem Aufruf, alles oder nichts
    p = os.path.join(proj, "demo", "m.py"); open(p, "w").write("a = 1\nb = 2\nc = 3\n")
    r = S.t_edit({"path": "demo/m.py", "edits": [{"old": "a = 1", "new": "a = 10"}, {"old": "c = 3", "new": "c = 30"}]}, {})
    say(open(p).read() == "a = 10\nb = 2\nc = 30\n" and "Sofortpruefung: OK" in r, "edit_file: mehrere Aenderungen in einem Aufruf", r)
    err = fails(lambda: S.t_edit({"path": "demo/m.py", "edits": [{"old": "b = 2", "new": "b = 20"}, {"old": "gibts nicht", "new": "x"}]}, {}))
    say(err and "Aenderung 2 von 2" in err and open(p).read() == "a = 10\nb = 2\nc = 30\n", "edit_file: passt eine Aenderung nicht, bleibt die Datei unveraendert", err)
    r = S.t_edit({"path": "demo/m.py", "edits": json.dumps([{"old": "b = 2", "new": "b = 20"}])}, {})
    say("b = 20" in open(p).read(), "edit_file: edits auch als JSON-Text", r)
    S.SHELL_OK = False

    # 4) Auto-Weiter: nach MAX_ITER_DEV Schritten geht es von selbst weiter, am Ende kommt der Abschlussbericht
    S.MAX_ITER_DEV, S.AUTO_ROUNDS = 3, 2
    n = [0]; final = []
    def busy(messages, emit, fast=False, tools=True, think=False, temp=0.7, tool_list=None, stats=None):
        if not tools: final.append(messages[-1]["content"]); return "Bericht", []
        n[0] += 1
        return "", [{"id": "n%d" % n[0], "name": "note", "args": json.dumps({"text": "Schritt %d" % n[0]})}]
    S.llm_stream = busy; evs = []
    S.chat([{"role": "user", "text": "los", "images": []}], evs.append, dev={"repo": "", "token": ""})
    cont = [ev for ev in evs if ev.get("type") == "stat" and "automatisch weiter" in ev.get("text", "")]
    say(n[0] == 9 and len(cont) == 2 and final and "Schrittlimit" in final[0], "Auto-Weiter: 2 zusaetzliche Runden, danach Abschlussbericht", (n[0], len(cont)))
    S.MAX_ITER_DEV, S.AUTO_ROUNDS = 60, 2

    # 5) git_push wartet auf den Build, wenn das Projekt einen Workflow hat
    d = os.path.join(proj, "demo")
    say(S._push_build({"project": "demo"}, {}, d) == "", "kein Workflow: git_push wartet nicht")
    os.makedirs(os.path.join(d, ".github", "workflows")); open(os.path.join(d, ".github", "workflows", "b.yml"), "w").write("on: push\n")
    S.t_build = lambda a, cfg: "Lauf 1: completed, Ergebnis success"
    r = S._push_build({"project": "demo"}, {}, d)
    say("BUILD-ERGEBNIS" in r and "success" in r, "mit Workflow: git_push meldet das Build-Ergebnis", r)
    say(S._push_build({"project": "demo", "wait_build": False}, {}, d) == "", "wait_build=false: git_push wartet nicht")


def test_images(S):
    try:
        import numpy as np
        from PIL import Image, ImageDraw, ImageEnhance
    except Exception:
        print("HINWEIS Bild-Tests uebersprungen (Pillow/numpy fehlen hier, auf dem Pod vorhanden)"); return
    random.seed(3); W, H = 1512, 2016
    o = Image.linear_gradient("L").resize((W, H)).convert("RGB"); d = ImageDraw.Draw(o)
    for _ in range(250):
        x, y, r = random.randrange(W), random.randrange(H), random.randrange(15, 120)
        d.ellipse([x, y, x + r, y + r], fill=tuple(random.randrange(256) for _ in range(3)))
    def enc(im, fmt="JPEG"):
        b = io.BytesIO(); im.save(b, fmt, quality=95); return b.getvalue()
    small = o.resize((864, 1152), Image.LANCZOS)
    box = (300, 300, 500, 500); edit = small.copy(); ImageDraw.Draw(edit).rectangle(box, fill=(200, 0, 200))
    sx = W / 864.0
    outside = np.ones((H, W), bool); outside[int(280 * sx):int(520 * sx), int(280 * sx):int(520 * sx)] = False
    inside = (slice(int(330 * sx), int(470 * sx)), slice(int(330 * sx), int(470 * sx)))
    O = np.asarray(o, np.float32)
    def run(ai, orig_fmt="JPEG"):
        out = S.keep_original(enc(o, orig_fmt), enc(ai.resize((W, H), Image.LANCZOS), "PNG"))
        return out, np.asarray(Image.open(io.BytesIO(out)).convert("RGB"), np.float32)

    # lokale Aenderung, KI-Bild 3/2 px verschoben und 6 % heller (typisch fuer Qwen-Edit)
    shifted = Image.new("RGB", edit.size); shifted.paste(ImageEnhance.Brightness(edit).enhance(1.06), (3, 2))
    raw = np.asarray(shifted.resize((W, H), Image.LANCZOS), np.float32)
    out, R = run(shifted)
    before = np.abs(raw - O).max(2)[outside].mean(); after = np.abs(R - O).max(2)[outside].mean()
    say(after < before * 0.35, "Bildabgleich: verschobenes, helleres KI-Bild -> ausserhalb der Aenderung fast Original (%.1f -> %.1f)" % (before, after))
    say(np.abs(R[inside] - np.array([200, 0, 200])).mean() < 40, "Bildabgleich: die gewollte Aenderung ist im Ergebnis")
    say(out[:2] == b"\xff\xd8", "Ergebnis als JPEG, wenn das Original JPEG ist")
    # KI-Bild 1 % gezoomt (ebenfalls typisch)
    z, cx, cy = 1.01, 432, 576
    zoomed = edit.transform(edit.size, Image.AFFINE, (1 / z, 0, cx * (1 - 1 / z), 0, 1 / z, cy * (1 - 1 / z)), Image.BICUBIC)
    raw = np.asarray(zoomed.resize((W, H), Image.LANCZOS), np.float32); _, R = run(zoomed)
    inner = outside.copy(); inner[:40] = inner[-40:] = False; inner[:, :40] = inner[:, -40:] = False
    before = np.abs(raw - O).max(2)[inner].mean(); after = np.abs(R - O).max(2)[inner].mean()
    say(after < before * 0.35, "Bildabgleich: 1 %% gezoomtes KI-Bild wird zurueckgerechnet (%.1f -> %.1f)" % (before, after))
    out, _ = run(shifted, "PNG")
    say(out[:4] == b"\x89PNG", "Ergebnis als PNG, wenn das Original PNG ist")
    # gewollte globale Aenderung ('mach es deutlich heller') wird nicht zurueckgedreht
    bright = ImageEnhance.Brightness(small).enhance(1.35)
    _, R = run(bright)
    say(R.mean() > O.mean() * 1.15, "Bildabgleich: gewollte starke Aufhellung bleibt erhalten (%.0f vs %.0f)" % (R.mean(), O.mean()))


def main():
    tmp = tempfile.mkdtemp(prefix="satanic_unit_")
    try:
        S = load(tmp)
        test_edit(S, os.environ["PROJECTS"])
        test_compact(S)
        test_devserver(S)
        test_dev_loop(S, os.environ["PROJECTS"])
        test_images(S)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
