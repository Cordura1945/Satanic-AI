#!/usr/bin/env python3
"""Probelauf fuer den Chat-Server (chat/server.py + chat/index.html).

Startet den Server in einem Wegwerf-Ordner auf einem freien Port, haengt ein
nachgebautes Sprachmodell dran und prueft die wichtigsten Wege:
Startseite, normale Antwort, Dev-Einstellungen, ein Werkzeug-Schritt im Dev-Modus.

Aufruf:  python3 tools/smoke_test.py     (Rueckgabe 0 = alles in Ordnung)
"""
import json, os, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    return p


class FakeLLM(BaseHTTPRequestHandler):
    """Antwortet wie das Sprachmodell: erst ein Werkzeugaufruf (wenn WERKZEUG verlangt ist), dann Text."""
    def log_message(self, *a): pass

    def do_GET(self):
        b = b'{"status":"ok"}'
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        msgs = body.get("messages") or []
        text = json.dumps(msgs[-1:], ensure_ascii=False)
        had_tool = any(m.get("role") == "tool" for m in msgs)
        want_tool = "WERKZEUG" in json.dumps(msgs, ensure_ascii=False) and body.get("tools") and not had_tool
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Connection", "close"); self.end_headers()

        def ev(delta):
            self.wfile.write(b"data: " + json.dumps({"choices": [{"delta": delta}]}).encode() + b"\n\n"); self.wfile.flush()
        if want_tool:
            ev({"tool_calls": [{"index": 0, "id": "call_1", "function": {"name": "list_files", "arguments": "{}"}}]})
        else:
            ev({"content": "Probelauf bestanden."})
        # Schluss-Paket wie bei llama.cpp: Abbruchgrund und Zeitwerte
        self.wfile.write(b"data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": "tool_calls" if want_tool else "stop"}],
                                                 "timings": {"prompt_n": 42, "prompt_ms": 100, "cache_n": 7, "predicted_n": 5, "predicted_ms": 50}}).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush(); self.close_connection = True


def main():
    results = []

    def say(ok, what, extra=""):
        results.append(ok)
        print(("OK     " if ok else "FEHLER ") + what + (("\n" + extra) if (extra and not ok) else ""))

    tmp = tempfile.mkdtemp(prefix="satanic_probe_")
    proc = None
    try:
        for f in ("server.py", "index.html"):
            shutil.copy(os.path.join(ROOT, "chat", f), os.path.join(tmp, f))
        llm_port, port = free_port(), free_port()
        llm = ThreadingHTTPServer(("127.0.0.1", llm_port), FakeLLM)
        threading.Thread(target=llm.serve_forever, daemon=True).start()
        env = {k: v for k, v in os.environ.items() if k not in ("RUNPOD_POD_ID", "CONTAINER_ID", "CONTAINER_API_KEY")}
        env.update({"APP_PORT": str(port), "STORE": os.path.join(tmp, "store"), "PROJECTS": os.path.join(tmp, "projects"),
                    "LLM_URL": f"http://127.0.0.1:{llm_port}", "LLM_FAST_URL": f"http://127.0.0.1:{llm_port}",
                    "COMFY_URL": f"http://127.0.0.1:{free_port()}", "IDLE_STOP_MIN": "0", "AUTO_STOP_H": "0", "AGENT_USER": "__keiner__"})
        os.makedirs(env["STORE"]); os.makedirs(env["PROJECTS"])
        log = open(os.path.join(tmp, "server.log"), "wb")
        proc = subprocess.Popen([sys.executable, os.path.join(tmp, "server.py")], cwd=tmp, env=env, stdout=log, stderr=subprocess.STDOUT)
        base = f"http://127.0.0.1:{port}"

        def get(path):
            with urllib.request.urlopen(base + path, timeout=20) as r:
                return r.status, r.read()

        def post(path, obj):
            rq = urllib.request.Request(base + path, json.dumps(obj).encode(), method="POST")
            try:
                with urllib.request.urlopen(rq, timeout=60) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, e.read()

        def chat(obj):
            st, raw = post("/api/chat", obj)
            return [json.loads(l[5:]) for l in raw.decode("utf-8", "replace").split("\n") if l.startswith("data:")]

        up = False
        for _ in range(60):
            if proc.poll() is not None: break
            try:
                st, page = get("/"); up = st == 200; break
            except Exception:
                time.sleep(0.25)
        logtxt = lambda: open(os.path.join(tmp, "server.log"), "rb").read().decode("utf-8", "replace")[-1500:]
        say(up, "Chat-Server startet", logtxt())
        if not up: return 1
        say(b"</html>" in page and b'id="msgs"' in page, "Startseite wird ausgeliefert")

        evs = chat({"messages": [{"role": "user", "text": "Hallo", "images": []}], "imgopts": {}})
        txt = "".join(e.get("text", "") for e in evs if e.get("type") == "delta")
        say("Probelauf bestanden" in txt and any(e.get("type") == "done" for e in evs) and not any(e.get("type") == "error" for e in evs),
            "normale Antwort kommt an", json.dumps(evs)[:600])

        st, raw = post("/api/dev", {"action": "save", "key": "probelauf-passwort"})
        say(st == 200 and json.loads(raw).get("ok") is True, "Dev-Einstellungen lassen sich speichern", raw.decode("utf-8", "replace")[:300])
        st, raw = post("/api/dev", {"action": "status", "key": "falsches-passwort"})
        say(st == 200 and json.loads(raw).get("ok") is False, "falsches Dev-Passwort wird abgelehnt")

        evs = chat({"messages": [{"role": "user", "text": "WERKZEUG bitte", "images": []}], "imgopts": {}, "dev": True, "devkey": "probelauf-passwort"})
        txt = "".join(e.get("text", "") for e in evs if e.get("type") == "delta")
        say(any(e.get("type") == "tool" for e in evs) and "Probelauf bestanden" in txt and not any(e.get("type") in ("error", "step") for e in evs),
            "Werkzeug-Schritt im Dev-Modus laeuft durch", json.dumps(evs)[:600])
        say(any(e.get("type") == "stat" and "eingelesen 42 Tokens" in e.get("text", "") for e in evs),
            "Zeitmessung im Dev-Modus kommt an", json.dumps([e for e in evs if e.get("type") == "stat"])[:300])

        evs = chat({"messages": [{"role": "user", "text": "WERKZEUG bitte", "images": []}], "imgopts": {}, "dev": True, "devkey": "falsch"})
        say(any(e.get("type") == "error" for e in evs), "Dev-Modus ohne gueltiges Passwort bleibt gesperrt")

        try:
            get("/api/job?id=gibt_es_nicht"); ok = False
        except urllib.error.HTTPError as e:
            ok = e.code == 404
        say(ok, "unbekannter Auftrag liefert 404")
        say(proc.poll() is None, "Server laeuft nach den Tests noch", logtxt())
        return 0 if all(results) else 1
    finally:
        if proc and proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=5)
            except Exception: proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
