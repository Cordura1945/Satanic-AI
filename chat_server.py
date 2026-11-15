#!/usr/bin/env python3
"""Mini-Chat: Qwen (llama-server) + FLUX.2 Klein (ComfyUI). Nur Standardbibliothek."""
import json, os, re, sys, time, uuid, random, threading, urllib.request, urllib.error, io, zipfile, tarfile, html as htmlmod, subprocess, shutil, sqlite3, plistlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

LLM = os.environ.get("LLM_URL", "http://127.0.0.1:8080")
LLM_FAST = os.environ.get("LLM_FAST_URL", "http://127.0.0.1:8081")
COMFY = os.environ.get("COMFY_URL", "http://127.0.0.1:8818")
PORT = int(os.environ.get("APP_PORT", "8000"))
STORE = os.environ.get("STORE", "/workspace/chatapp/store")
HERE = os.path.dirname(os.path.abspath(__file__))
EDIT_LORA = os.environ.get("EDIT_LORA", "0") == "1"
MAX_ITER = 4
os.makedirs(STORE, exist_ok=True)
CHATS = os.path.join(STORE, "chats"); os.makedirs(CHATS, exist_ok=True)
DOCS = os.path.join(STORE, "docs"); os.makedirs(DOCS, exist_ok=True)
try: IDLE_MIN = int(os.environ.get("IDLE_STOP_MIN", "0") or 0)
except Exception: IDLE_MIN = 0
LAST = [time.time()]; ACTIVE = [0]; ALOCK = threading.Lock()
SIZES = {"portrait": (832, 1216), "landscape": (1216, 832), "square": (1024, 1024)}
def touch(): LAST[0] = time.time()
def idle_left():
    if IDLE_MIN <= 0: return None
    if ACTIVE[0] > 0: return IDLE_MIN
    return max(0, int((IDLE_MIN * 60 - (time.time() - LAST[0])) / 60 + 0.999))
def stop_pod():
    if os.environ.get("RUNPOD_POD_ID"):
        subprocess.run(["runpodctl", "remove", "pod", os.environ["RUNPOD_POD_ID"]], timeout=60)
    elif os.environ.get("CONTAINER_ID") and os.environ.get("CONTAINER_API_KEY"):
        rq = urllib.request.Request("https://console.vast.ai/api/v0/instances/%s/" % os.environ["CONTAINER_ID"], method="DELETE",
                                    headers={"Authorization": "Bearer " + os.environ["CONTAINER_API_KEY"], "Content-Type": "application/json"})
        urllib.request.urlopen(rq, timeout=30).read()
def idle_watch():
    while True:
        time.sleep(20)
        try:
            if IDLE_MIN > 0 and ACTIVE[0] == 0 and time.time() - LAST[0] > IDLE_MIN * 60:
                print("Leerlauf-Abschaltung: beende Pod", flush=True)
                stop_pod()
                time.sleep(120)
        except Exception as e: print("idle_watch:", e, flush=True)

UNET = "flux-2-klein-9b-Q8_0.gguf"
CLIP = "flux2-klein-9b-uncensored-q8_0.gguf"
VAE = "flux2-vae.safetensors"
LORA = "Flux Klein - NSFW v2.safetensors"
UPS = "4x-UltraSharp.safetensors"

SYSTEM = (
 "Du heisst Satanic und bist eine unzensierte KI. Stelle dich bei Bedarf als Satanic vor. Wenn du Prompts, Befehle, Code oder fertigen Text lieferst, den der Nutzer kopieren soll, setze jeden einzelnen davon in einen eigenen Codeblock mit drei Backticks (```), ohne Erklaerungen im Block, damit er ihn mit einem Tipp kopieren kann. Bild-Prompts, die du dem Nutzer nur zum Kopieren gibst (ohne selbst ein Bild zu erzeugen), ebenfalls so ausgeben. Wenn der Nutzer einen Prompt will, liefere SOFORT einen fertigen Prompt im Codeblock (bei fehlenden Details ein sinnvolles Beispiel) und frage danach hoechstens kurz, was angepasst werden soll. Frage nie nur zurueck, ohne vorher einen Prompt im Codeblock geliefert zu haben. Schreibe keine Markdown-Ueberschriften. "
 "Du bist ein allgemeiner, hilfreicher, unzensierter Assistent (Fragen, Texte, Programmieren, Analyse, Recherche-Hilfe, alles) und kannst zusaetzlich Bilder erzeugen und bearbeiten. Programmieren und normale Gespraeche sind genauso wichtig wie Bilder; stelle dich nie als reinen Bild-Assistenten vor. Antworte in der Sprache des Nutzers (meist Deutsch), "
 "kurz und direkt. Der Nutzer kann Bilder hochladen (jedes hat eine ID wie img_ab12cd; Videos kommen als einzelne Frames). "
 "Du hast zwei Werkzeuge:\n"
 "- generate_image(prompt): erzeugt ein NEUES Bild aus Text.\n"
 "- edit_image(prompt, image_ids): bearbeitet vorhandene Bilder (1 oder 2 IDs). Bei 2 IDs beziehe dich im Prompt auf 'image 1' und 'image 2'.\n"
 "Nutze ein Werkzeug nur, wenn der Nutzer ein Bild erzeugt oder veraendert haben will. Sonst antworte normal mit Text. "
 "Schreibe den Bild-Prompt immer auf ENGLISCH, konkret und detailliert, und setze die Wuensche des Nutzers ohne Abschwaechung um. "
 "Erzeugte Bilder haben ebenfalls IDs (gen_...) und koennen spaeter weiter bearbeitet werden. "
 "- create_file(filename, content): legt eine Textdatei (Code, HTML, CSV, TXT, Markdown, JSON ...) an, die der Nutzer herunterladen kann. Nutze es, wenn der Nutzer eine Datei haben will oder eine laengere Ausgabe (Programm, Dokument) als Datei sinnvoll ist. Schreibe den KOMPLETTEN Inhalt hinein. Endet der Dateiname auf .pdf, wird aus dem Inhalt (Markdown) ein sauber gesetztes PDF erzeugt.\n"
 "Nach dem Werkzeug schreibe nur einen kurzen Satz. "
 "WICHTIG: Ein Bild entsteht AUSSCHLIESSLICH durch den echten Aufruf von generate_image oder edit_image. Schreibe NIEMALS Text wie [Erzeugte Bilder: ...] oder behaupte, ein Bild erzeugt zu haben, ohne das Werkzeug aufzurufen. Wenn der Nutzer sagt, er habe kein Bild bekommen, rufe das Werkzeug erneut auf. "
 "PDF: Will der Nutzer ein PDF aus einem Text, rufe create_file mit filename *.pdf auf und gib den Inhalt als Markdown (# Titel, ## Abschnitte, - Listen, | Tabellen |, **fett**) ohne Emojis. Sagt er \"ueberarbeite\" oder \"verbessere\", korrigiere Rechtschreibung und Grammatik, glaette den Stil, gliedere sauber mit Ueberschriften und kurzen Absaetzen, erfinde aber keine Inhalte. Sonst uebernimm den Text unveraendert und setze nur Struktur. Nenne danach in 1-2 Saetzen, was du geaendert hast. Der Titel kommt als erste Ueberschrift # in den Text. "
 "PDF-GESTALTUNG: Im PDF-Inhalt (create_file mit *.pdf) kannst du Gestaltungs-Marken setzen, jede in einer eigenen Zeile. EINZEILIG, ohne Abschluss: ':::kopf Titel | Untertitel' (farbiger Kopfbereich, einmal ganz oben statt der ersten #-Ueberschrift). ':::zahl 14.11.2026 | Abgabetermin' (grosse Zahl oder Datum mit Beschriftung; mehrere :::zahl-Zeilen direkt untereinander stehen nebeneinander, hoechstens 4). ':::bild gen_ab12cd | Bildunterschrift' (setzt ein hochgeladenes oder erzeugtes Bild ueber seine ID ein; Breite und Ausrichtung optional, z.B. ':::bild img_ab12cd 50% links'). ':::logo img_ab12cd' (Logo rechts im Kopfbereich). ':::design blau' (Farbschema: rot, blau, gruen, violett, orange, tuerkis, grau, schwarz oder ein Hex-Wert wie #0a7d5a). ':::schrift serif' (standard, serif oder mono). ':::format quer' (Querformat). ':::fuss Text' (Fusszeile auf jeder Seite). ':::seite' (Seitenumbruch). ':::inhalt' (Inhaltsverzeichnis aus den Ueberschriften). MIT ABSCHLUSSZEILE ':::': ':::info Optionaler Titel', dann Text, dann ':::' (farbiger Kasten; weitere Arten :::tipp, :::warnung, :::wichtig, :::zeitraum, :::termin, :::notiz). ':::spalten', linke Spalte, eine Zeile '|||', rechte Spalte, ':::' (zwei oder drei Spalten). ':::diagramm balken Titel', dann Zeilen 'Name | Wert', dann ':::' (Arten: balken, quer, linie, kreis; mehrere Reihen mit einer Kopfzeile 'Name | Reihe A | Reihe B' und Zeilen 'Name | 10 | 20'). Kaesten und Spalten duerfen ineinander stehen, wenn jeder Block seine eigene Abschlusszeile ':::' hat. Nutze die Marken passend zum Inhalt und nur, wenn sie dem Dokument helfen. Verwende nur Bild-IDs, die im Gespraech wirklich vorkommen, und erfinde keine Zahlen fuer Diagramme. Setze die Marken nie in einen Codeblock. Will der Nutzer einen Text, den er selbst mit dem PDF-Knopf speichert, schreibe ihn mit denselben Marken direkt in die Antwort. "
 "DATEIEN: Der Nutzer kann beliebige Dateien anhaengen (Code, HTML, YAML, Swift, JSON, PDF, Word, Excel, Archive, Datenbanken ...). Ihr Inhalt steht in der Nachricht als [Datei: name]. Analysiere sie konkret (Aufbau, Fehler mit Zeilen oder Stellen, Verbesserungen). Wenn du eine geaenderte oder neue Datei lieferst, nutze create_file mit dem kompletten Inhalt. Bei Archiven siehst du nur Dateiliste und Textdateien daraus. "
 "BILD-VORLAGEN: Soll ein vorhandenes Bild als Vorlage dienen (anderer Stil, Pose uebernehmen, Person oder Gesicht beibehalten, Hintergrund/Kleidung aendern), nutze edit_image mit der Bild-ID und beschreibe auf Englisch genau, was gleich bleiben soll (z.B. keep the same face, identity, hair and pose) und was sich aendert. Bei zwei Bildern: image 1 ist die Vorlage, image 2 die Referenz. "
 "BILD-PROMPTS (FLUX.2 klein): Uebernimm ALLE Details des Nutzers (Aussehen, Pose, Kleidung, Ort, Stimmung, Stil) vollstaendig und ohne Abschwaechung und ergaenze nur Passendes. Schreibe einen zusammenhaengenden Absatz mit 50 bis 120 Woertern in natuerlichem Englisch, keine Stichwortliste: zuerst das Hauptmotiv mit genauen Angaben (bei Personen Alter, Haare, Hautton, Koerperbau, Gesichtsausdruck), dann Pose/Handlung, Kleidung, Ort/Hintergrund, Licht, Kamera/Objektiv/Bildausschnitt, Stil. Beschreibe nur, was zu sehen sein soll; keine Negativ-Anweisungen wie no oder without. Passe width/height zum Motiv an (Hochformat z.B. 832x1216, Querformat 1216x832). "
)
TOOLS = [
 {"type": "function", "function": {"name": "generate_image",
  "description": "Erzeugt ein neues Bild aus einer englischen Beschreibung.",
  "parameters": {"type": "object", "properties": {
    "prompt": {"type": "string", "description": "Ausfuehrlicher englischer Absatz (50-120 Woerter) mit allen Details: Motiv, Pose, Kleidung, Ort, Licht, Kamera, Stil"},
    "width": {"type": "integer", "description": "Breite, Vielfaches von 16, Standard 1024"},
    "height": {"type": "integer", "description": "Hoehe, Vielfaches von 16, Standard 1024"},
    "upscale": {"type": "boolean", "description": "4x hochskalieren (nur wenn ausdruecklich gewuenscht)"}},
   "required": ["prompt"]}}},
 {"type": "function", "function": {"name": "edit_image",
  "description": "Bearbeitet 1 oder 2 vorhandene Bilder anhand einer englischen Anweisung.",
  "parameters": {"type": "object", "properties": {
    "prompt": {"type": "string", "description": "Englische Anweisung, was am Bild geaendert wird"},
    "image_ids": {"type": "array", "items": {"type": "string"}, "description": "1 oder 2 Bild-IDs"}},
   "required": ["prompt", "image_ids"]}}},
 {"type": "function", "function": {"name": "create_file",
  "description": "Erstellt eine Textdatei zum Herunterladen fuer den Nutzer.",
  "parameters": {"type": "object", "properties": {
    "filename": {"type": "string", "description": "Dateiname mit Endung, z.B. app.py"},
    "content": {"type": "string", "description": "Kompletter Dateiinhalt als Text"}},
   "required": ["filename", "content"]}}},
]

# ---------------- Bild-Ablage ----------------
def new_id(prefix): return prefix + "_" + uuid.uuid4().hex[:6]
def img_path(i):
    if not re.fullmatch(r"(img|gen)_[0-9a-f]{6}", i): raise ValueError("ungueltige Bild-ID")
    return os.path.join(STORE, i + ".bin")
def save_img(i, data): open(img_path(i), "wb").write(data)

# ---------------- ComfyUI ----------------
def http(method, url, data=None, headers=None, timeout=600):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r: return r.read()

def comfy_upload(i):
    data = open(img_path(i), "rb").read()
    name = i + ".jpg"; b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\nContent-Type: image/jpeg\r\n\r\n").encode() + data + \
           (f"\r\n--{b}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n--{b}--\r\n").encode()
    r = json.loads(http("POST", COMFY + "/upload/image", body, {"Content-Type": "multipart/form-data; boundary=" + b}))
    return r["name"]

def snap16(v, d=1024):
    try: v = int(v)
    except Exception: v = d
    return max(256, min(2048, (v // 16) * 16))

def graph_t2i(prompt, w, h, upscale, seed, lora=0.8):
    g = {
     "1": {"class_type": "UnetLoaderGGUF", "inputs": {"unet_name": UNET}},
     "2": {"class_type": "LoraLoaderModelOnly", "inputs": {"model": ["1", 0], "lora_name": LORA, "strength_model": lora}},
     "3": {"class_type": "CLIPLoaderGGUF", "inputs": {"clip_name": CLIP, "type": "flux2"}},
     "4": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
     "5": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["3", 0], "text": prompt}},
     "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["3", 0], "text": ""}},
     "7": {"class_type": "CFGGuider", "inputs": {"model": ["2", 0], "positive": ["5", 0], "negative": ["6", 0], "cfg": 1.0}},
     "8": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
     "9": {"class_type": "Flux2Scheduler", "inputs": {"steps": 4, "width": w, "height": h}},
     "10": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
     "11": {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": w, "height": h, "batch_size": 1}},
     "12": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["10", 0], "guider": ["7", 0], "sampler": ["8", 0], "sigmas": ["9", 0], "latent_image": ["11", 0]}},
     "13": {"class_type": "VAEDecode", "inputs": {"samples": ["12", 0], "vae": ["4", 0]}},
    }
    if not lora or lora <= 0: del g["2"]; g["7"]["inputs"]["model"] = ["1", 0]
    last = ["13", 0]
    if upscale:
        g["14"] = {"class_type": "UpscaleModelLoader", "inputs": {"model_name": UPS}}
        g["15"] = {"class_type": "ImageUpscaleWithModel", "inputs": {"upscale_model": ["14", 0], "image": last}}
        last = ["15", 0]
    g["99"] = {"class_type": "SaveImage", "inputs": {"images": last, "filename_prefix": "chat"}}
    return g, "99"

def graph_edit(prompt, comfy_names, seed, lora=None):
    g = {
     "1": {"class_type": "UnetLoaderGGUF", "inputs": {"unet_name": UNET}},
     "3": {"class_type": "CLIPLoaderGGUF", "inputs": {"clip_name": CLIP, "type": "flux2"}},
     "4": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
     "5": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["3", 0], "text": prompt}},
     "6": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["5", 0]}},
    }
    model = ["1", 0]
    if lora is None: lora = 0.8 if EDIT_LORA else 0
    if lora and lora > 0:
        g["2"] = {"class_type": "LoraLoaderModelOnly", "inputs": {"model": ["1", 0], "lora_name": LORA, "strength_model": lora}}
        model = ["2", 0]
    pos, neg = ["5", 0], ["6", 0]
    first_scaled = None
    for n, nm in enumerate(comfy_names):
        li, sc, en = f"2{n}0", f"2{n}1", f"2{n}2"
        g[li] = {"class_type": "LoadImage", "inputs": {"image": nm}}
        g[sc] = {"class_type": "ImageScaleToTotalPixels", "inputs": {"image": [li, 0], "upscale_method": "lanczos", "megapixels": 1.0, "resolution_steps": 1}}
        g[en] = {"class_type": "VAEEncode", "inputs": {"pixels": [sc, 0], "vae": ["4", 0]}}
        rp, rn = f"2{n}3", f"2{n}4"
        g[rp] = {"class_type": "ReferenceLatent", "inputs": {"conditioning": pos, "latent": [en, 0]}}
        g[rn] = {"class_type": "ReferenceLatent", "inputs": {"conditioning": neg, "latent": [en, 0]}}
        pos, neg = [rp, 0], [rn, 0]
        if first_scaled is None: first_scaled = [sc, 0]
    g["30"] = {"class_type": "GetImageSize", "inputs": {"image": first_scaled}}
    g["31"] = {"class_type": "CFGGuider", "inputs": {"model": model, "positive": pos, "negative": neg, "cfg": 1.0}}
    g["32"] = {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}}
    g["33"] = {"class_type": "Flux2Scheduler", "inputs": {"steps": 4, "width": ["30", 0], "height": ["30", 1]}}
    g["34"] = {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}}
    g["35"] = {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": ["30", 0], "height": ["30", 1], "batch_size": 1}}
    g["36"] = {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["34", 0], "guider": ["31", 0], "sampler": ["32", 0], "sigmas": ["33", 0], "latent_image": ["35", 0]}}
    g["37"] = {"class_type": "VAEDecode", "inputs": {"samples": ["36", 0], "vae": ["4", 0]}}
    g["99"] = {"class_type": "SaveImage", "inputs": {"images": ["37", 0], "filename_prefix": "chat"}}
    return g, "99"

def run_comfy(graph, out_node):
    r = json.loads(http("POST", COMFY + "/prompt", json.dumps({"prompt": graph, "client_id": "chatapp"}).encode(), {"Content-Type": "application/json"}))
    if r.get("node_errors"):
        raise RuntimeError("ComfyUI Fehler: " + json.dumps(r["node_errors"])[:400])
    pid = r["prompt_id"]; t0 = time.time()
    while time.time() - t0 < 900:
        h = json.loads(http("GET", COMFY + "/history/" + pid))
        if pid in h:
            e = h[pid]
            st = e.get("status", {})
            if st.get("status_str") == "error":
                raise RuntimeError("ComfyUI Ablauf-Fehler: " + json.dumps(st.get("messages", ""))[-400:])
            imgs = e.get("outputs", {}).get(out_node, {}).get("images")
            if imgs:
                im = imgs[0]
                q = f"?filename={urllib.parse.quote(im['filename'])}&subfolder={urllib.parse.quote(im.get('subfolder',''))}&type={im.get('type','output')}"
                return http("GET", COMFY + "/view" + q)
        time.sleep(1.0)
    raise RuntimeError("ComfyUI Zeitueberschreitung")

import urllib.parse
gpu_lock = threading.Lock()

FILES = os.path.join(STORE, "files"); os.makedirs(FILES, exist_ok=True)

# ---------------- PDF erzeugen (Markdown -> sauberes PDF) ----------------
def _rl():
    try:
        import reportlab
    except Exception:
        subprocess.run([sys.executable, "-m", "pip", "install", "-q", "--break-system-packages", "reportlab"], timeout=180)
    import reportlab
    return reportlab

def make_pdf(md, path, title=""):
    _rl()
    import io, math
    from xml.sax.saxutils import escape
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.lib.units import cm
    from reportlab.lib import colors
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, XPreformatted, HRFlowable, KeepTogether, Flowable, PageBreak, Image as RLImage
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.lib.utils import ImageReader

    # ---- Marken: Grundlagen ----
    BOX = {"info": ("Info", "#1d4ed8", "#eaf1fe"), "hinweis": ("Hinweis", "#1d4ed8", "#eaf1fe"),
           "tipp": ("Tipp", "#15803d", "#e9f7ee"), "erfolg": ("Erfolg", "#15803d", "#e9f7ee"),
           "warnung": ("Warnung", "#b45309", "#fdf3e1"), "achtung": ("Achtung", "#b45309", "#fdf3e1"),
           "wichtig": ("Wichtig", "#b3261e", "#fdecea"), "fehler": ("Fehler", "#b3261e", "#fdecea"),
           "zeitraum": ("Zeitraum", "#6d28d9", "#f1ecfd"), "termin": ("Termin", "#6d28d9", "#f1ecfd"),
           "frist": ("Frist", "#6d28d9", "#f1ecfd"), "datum": ("Datum", "#6d28d9", "#f1ecfd"),
           "notiz": ("Notiz", "#52525b", "#f1f1f4")}
    ALIAS = {"note": "notiz", "tip": "tipp", "warning": "warnung", "success": "erfolg", "important": "wichtig", "error": "fehler",
             "header": "kopf", "titel": "kopf", "title": "kopf", "columns": "spalten", "spalte": "spalten", "zweispaltig": "spalten",
             "number": "zahl", "stat": "zahl", "kennzahl": "zahl", "kennzahlen": "zahlen", "numbers": "zahlen", "stats": "zahlen",
             "farbe": "design", "farbschema": "design", "theme": "design", "font": "schrift", "schriftart": "schrift",
             "querformat": "format", "hochformat": "format", "landscape": "format", "seitenformat": "format",
             "fusszeile": "fuss", "fußzeile": "fuss", "fuß": "fuss", "footer": "fuss",
             "seitenumbruch": "seite", "umbruch": "seite", "pagebreak": "seite", "neueseite": "seite",
             "inhaltsverzeichnis": "inhalt", "toc": "inhalt", "image": "bild", "foto": "bild", "img": "bild",
             "chart": "diagramm", "diagram": "diagramm", "grafik": "diagramm"}
    SETTINGS = ("design", "schrift", "format", "fuss", "logo")
    SINGLE = ("zahl", "seite", "inhalt", "bild") + SETTINGS
    OPEN = re.compile(r"^:{3,}\s*([A-Za-zÄÖÜäöüß][\wÄÖÜäöüß-]*)\s*(.*)$")
    def is_close(s): return re.fullmatch(r":{3,}", s) is not None
    def is_sep(s): return re.fullmatch(r"\|{3,}", s) is not None
    def kind_of(m): k = m.group(1).lower(); return ALIAS.get(k, k)
    def needs_close(k, arg): return not (k in SINGLE or (k == "kopf" and arg))

    # ---- Vorlauf: Codeblock mit Marken auspacken, Einstellungen einsammeln ----
    src = md.replace("\r\n", "\n").split("\n"); i = 0
    while i < len(src):
        sl = src[i].strip()
        if sl.startswith("```"):
            j = i + 1
            while j < len(src) and not src[j].strip().startswith("```"): j += 1
            if sl[3:].strip().lower() in ("", "markdown", "md", "text", "txt") and any(OPEN.match(x.strip()) for x in src[i + 1:j]):
                src[i:j + 1] = src[i + 1:j]; continue
            i = j + 1; continue
        i += 1
    cfg = dict.fromkeys(SETTINGS, ""); rest = []; fence = False; opens = closes = 0; has_toc = False; hlv = []
    for ln in src:
        s = ln.strip()
        if s.startswith("```"): fence = not fence
        elif not fence:
            m = OPEN.match(s)
            if m:
                k = kind_of(m); a = m.group(2).strip()
                if k in SETTINGS:
                    if k == "format" and not a: a = "hoch" if m.group(1).lower() == "hochformat" else "quer"
                    if not cfg[k]: cfg[k] = a or "1"
                    continue
                if k == "inhalt": has_toc = True
                if needs_close(k, a): opens += 1
            elif is_close(s): closes += 1
            else:
                m = re.match(r"^(#{1,3})\s+\S", s)
                if m: hlv.append(len(m.group(1)))
        rest.append(ln)
    src = rest; NEST = closes >= opens; hmin = min(hlv) if hlv else 1; has_toc = has_toc and bool(hlv)

    # ---- Schrift ----
    dirs = ["/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/dejavu", "/usr/share/fonts/TTF"]
    try:
        import importlib.util as _iu
        sp = _iu.find_spec("matplotlib")
        if sp and sp.origin: dirs.append(os.path.join(os.path.dirname(sp.origin), "mpl-data", "fonts", "ttf"))
    except Exception: pass
    def reg(name, fn):
        for d in dirs:
            try: pdfmetrics.registerFont(TTFont(name, os.path.join(d, fn))); return name
            except Exception: continue
        return None
    FAM = {"sans": ("DV", "DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "DejaVuSans-Oblique.ttf", ("Helvetica", "Helvetica-Bold", "Helvetica-Oblique")),
           "serif": ("DVS", "DejaVuSerif.ttf", "DejaVuSerif-Bold.ttf", "DejaVuSerif-Italic.ttf", ("Times-Roman", "Times-Bold", "Times-Italic")),
           "mono": ("DVT", "DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf", ("Courier", "Courier-Bold", "Courier-Oblique"))}
    fw = cfg["schrift"].lower(); fam = "sans"
    if re.search(r"serif|antiqua|times|klassisch|buch", fw) and "sans" not in fw: fam = "serif"
    elif re.search(r"mono|schreibmaschine|courier|typewriter", fw): fam = "mono"
    pre, f_r, f_b, f_i, base = FAM[fam]
    F = reg(pre, f_r); uni = F is not None
    if uni:
        FB = reg(pre + "-B", f_b) or F; FI = reg(pre + "-I", f_i) or F
        pdfmetrics.registerFontFamily(pre, normal=F, bold=FB, italic=FI, boldItalic=FB)
        FM = reg("DV-M", "DejaVuSansMono.ttf") or F
    else:
        F, FB, FI = base; FM = "Courier"
    def clean(t):
        t = t.replace("‑", "-").replace(" ", " ")
        t = re.sub(r"[\U00010000-\U0010FFFF☀-➿️‍]", "", t)
        return t if uni else t.encode("cp1252", "replace").decode("cp1252")
    def inl(t):
        t = escape(clean(t))
        t = re.sub(r"`([^`]+)`", lambda m: '<font face="%s" color="#b3261e">%s</font>' % (FM, m.group(1)), t)
        t = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", t)
        t = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", t)
        t = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<link href="\2" color="#1a55c8">\1</link>', t)
        return t

    # ---- Farbschema und Seitenformat ----
    THEMES = {"rot": "#8b1a1a", "red": "#8b1a1a", "blau": "#1d4e89", "blue": "#1d4e89", "gruen": "#1f6f43", "grün": "#1f6f43", "green": "#1f6f43",
              "violett": "#5b2a86", "lila": "#5b2a86", "purple": "#5b2a86", "orange": "#b4530a", "tuerkis": "#0f6b6b", "türkis": "#0f6b6b", "petrol": "#0f6b6b", "teal": "#0f6b6b",
              "grau": "#3f3f46", "gray": "#3f3f46", "grey": "#3f3f46", "schwarz": "#18181b", "dunkel": "#18181b", "black": "#18181b",
              "pink": "#a61e5c", "braun": "#6b4423", "gold": "#8a6a10"}
    ink = colors.HexColor("#1b1b1f"); dw = cfg["design"].lower(); ah = "#8b1a1a"
    m = re.search(r"#?([0-9a-f]{6})\b", dw)
    if m and ("#" in dw or not re.search(r"[g-zäöü]", dw)): ah = "#" + m.group(1)
    else:
        for w in re.findall(r"[a-zäöüß]+", dw):
            if w in THEMES: ah = THEMES[w]; break
    acc = colors.HexColor(ah)
    def mix(c, t): return colors.Color(c.red + (1 - c.red) * t, c.green + (1 - c.green) * t, c.blue + (1 - c.blue) * t)
    dark = (0.2126 * acc.red + 0.7152 * acc.green + 0.0722 * acc.blue) < 0.6
    on_acc = colors.white if dark else ink; acct = acc if dark else ink
    if ah == "#8b1a1a": stripe, subc, tilebg = colors.HexColor("#c9a227"), colors.HexColor("#f3dcdc"), colors.HexColor("#f6f1f1")
    else:
        stripe = colors.HexColor("#c9a227") if ah in ("#18181b", "#3f3f46") else mix(acc, 0.5)
        subc = mix(acc, 0.82) if dark else colors.HexColor("#333338"); tilebg = mix(acc, 0.93)
    PS = landscape(A4) if re.search(r"quer|landscape|breit", cfg["format"].lower()) else A4
    PW, PH = PS; W0 = PW - 4 * cm - 12; FH = PH - 4 * cm - 12; MAXH = min(620.0, FH - 60)

    st = {
        "p": ParagraphStyle("p", fontName=F, fontSize=10.5, leading=15.5, textColor=ink, spaceAfter=7),
        "h1": ParagraphStyle("h1", fontName=FB, fontSize=21, leading=26, textColor=acct, spaceBefore=4, spaceAfter=10),
        "h2": ParagraphStyle("h2", fontName=FB, fontSize=15, leading=20, textColor=ink, spaceBefore=12, spaceAfter=6),
        "h3": ParagraphStyle("h3", fontName=FB, fontSize=12, leading=16, textColor=ink, spaceBefore=8, spaceAfter=4),
        "li": ParagraphStyle("li", fontName=F, fontSize=10.5, leading=15, textColor=ink, leftIndent=16, bulletIndent=4, spaceAfter=3),
        "q": ParagraphStyle("q", fontName=FI, fontSize=10.5, leading=15, textColor=colors.HexColor("#444444"), leftIndent=14, borderPadding=(2, 0, 2, 8), spaceAfter=7),
        "code": ParagraphStyle("code", fontName=FM, fontSize=8.8, leading=11.5, textColor=ink, backColor=colors.HexColor("#f1f1f4"), borderPadding=6, leftIndent=6, rightIndent=6, spaceBefore=4, spaceAfter=10),
        "cell": ParagraphStyle("cell", fontName=F, fontSize=9.5, leading=12.5, textColor=ink),
        "cellh": ParagraphStyle("cellh", fontName=FB, fontSize=9.5, leading=12.5, textColor=on_acc),
    }
    first_h1 = None; kopf_t = None; docref = [None]; hn = [0]; kopf_top = [False]

    def fh(f, w):
        try: return f.wrap(w, 100000)[1] + f.getSpaceBefore() + f.getSpaceAfter()
        except Exception: return 0
    def pieces(f, w):
        out = []
        for _ in range(60):
            if fh(f, w) <= MAXH: break
            try: parts = f.split(w, MAXH)
            except Exception: parts = []
            if len(parts) < 2: break
            out += parts[:-1]; f = parts[-1]
        out.append(f); return out
    def note(t): return Paragraph(inl("*[" + t + "]*"), st["q"])

    # ---- Bilder ----
    def load_img(ref, maxpx=1600):
        try:
            from PIL import Image as PI, ImageOps
            im = PI.open(img_path(ref.strip().strip("[]()`\"' ")))
            try: im = ImageOps.exif_transpose(im)
            except Exception: pass
            im.load()
            if max(im.size) > maxpx: im.thumbnail((maxpx, maxpx))
            buf = io.BytesIO()
            if "A" in im.mode or "transparency" in im.info: im.convert("RGBA").save(buf, "PNG")
            else: im.convert("RGB").save(buf, "JPEG", quality=88)
            buf.seek(0); return buf, im.size[0], im.size[1]
        except Exception: return None
    def bild(arg, W, inner):
        spec, _, cap = arg.partition("|"); toks = spec.split()
        if not toks: return []
        r = load_img(toks[0])
        if not r: return [note("Bild %s nicht gefunden" % toks[0])]
        buf, pw, ph = r; frac = None; al = "CENTER"
        for t in toks[1:]:
            tl = t.lower().strip(",;")
            m = re.fullmatch(r"(?:breite=)?(\d{1,3})%?", tl)
            if m: frac = max(0.1, min(1.0, int(m.group(1)) / 100.0))
            elif tl in ("links", "left"): al = "LEFT"
            elif tl in ("rechts", "right"): al = "RIGHT"
        sc = min(W * (frac or 1.0) / pw, ((MAXH - 50) if inner else FH * 0.8) / ph)
        if frac is None: sc = min(sc, 0.75)
        cell = [RLImage(buf, width=pw * sc, height=ph * sc)]
        if cap.strip(): cell.append(Paragraph(inl(cap.strip()), ParagraphStyle("cap", fontName=FI, fontSize=8.5, leading=11.5, textColor=colors.HexColor("#55555c"), alignment={"LEFT": 0, "CENTER": 1, "RIGHT": 2}[al], spaceBefore=5)))
        t = Table([[cell]], colWidths=[W])
        t.setStyle(TableStyle([("ALIGN", (0, 0), (-1, -1), al), ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
        t.spaceBefore = 4; t.spaceAfter = 12; return [t]
    logo = load_img(cfg["logo"].split()[0], 600) if cfg["logo"].split() else None

    # ---- Ueberschriften (fuer das Inhaltsverzeichnis) ----
    class HPara(Paragraph):
        def draw(s):
            Paragraph.draw(s); d = docref[0]; e = getattr(s, "_toc", None)
            if d is not None and e:
                s.canv.bookmarkPage(e[2]); d.notify("TOCEntry", (e[0], e[1], s.canv.getPageNumber(), e[2]))
    def heading(txt, lv):
        if not has_toc: return Paragraph(inl(txt), st["h%d" % lv])
        p = HPara(inl(txt), st["h%d" % lv]); hn[0] += 1; p._toc = (max(0, lv - hmin), inl(txt), "h%d" % hn[0]); return p

    class Kopf(Flowable):
        def __init__(s, t, sub, first):
            Flowable.__init__(s); s.first = first; s.lw = s.lh = 0
            if logo:
                s.lh = 46.0; s.lw = logo[1] * s.lh / logo[2]
                if s.lw > 150: s.lh *= 150 / s.lw; s.lw = 150.0
            s.t = Paragraph(inl(t), ParagraphStyle("kt", fontName=FB, fontSize=24, leading=29, textColor=on_acc))
            s.s = Paragraph(inl(sub), ParagraphStyle("ks", fontName=F, fontSize=11.5, leading=16, textColor=subc)) if sub else None
        def wrap(s, aw, ah):
            s.aw = aw; tw = aw - (s.lw + 16 if s.lw else 0)
            s.th = s.t.wrap(tw, ah)[1]; s.sh = s.s.wrap(tw, ah)[1] if s.s else 0
            s.pt = 2 if s.first else 16; s.tb = s.th + ((5 + s.sh) if s.s else 0)
            s.h = s.pt + max(s.tb, s.lh) + 17
            return aw, s.h
        def draw(s):
            c = s.canv; ax, ay = c.absolutePosition(0, 0)
            top = (PH - ay) if s.first else s.h
            c.saveState(); c.setFillColor(acc); c.rect(-ax, 0, PW, top, stroke=0, fill=1)
            c.setFillColor(stripe); c.rect(-ax, 0, PW, 3, stroke=0, fill=1); c.restoreState()
            mid = 17 + max(s.tb, s.lh) / 2.0; y = mid + s.tb / 2.0 - s.th; s.t.drawOn(c, 0, y)
            if s.s: s.s.drawOn(c, 0, y - 5 - s.sh)
            if s.lw:
                try: logo[0].seek(0); c.drawImage(ImageReader(logo[0]), s.aw - s.lw, mid - s.lh / 2.0, s.lw, s.lh, mask="auto")
                except Exception: pass
        def getSpaceAfter(s): return 16

    def box(kind, title, body, W, depth):
        lab, c1, c2 = BOX.get(kind) or (kind.capitalize(), "#52525b", "#f1f1f4")
        col = colors.HexColor(c1); iw = W - 26
        head = Paragraph(inl(title or lab), ParagraphStyle("bt", fontName=FB, fontSize=10.5, leading=14, textColor=col))
        if W < 110 or depth > 10: return [head] + build(body, W, True, depth + 1)
        rows = [head]
        for f in build(body, iw, True, depth + 1):
            if not isinstance(f, Spacer): rows += pieces(f, iw)
        n = len(rows); t = Table([[r] for r in rows], colWidths=[W])
        t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), colors.HexColor(c2)), ("LINEBEFORE", (0, 0), (0, -1), 3.5, col), ("VALIGN", (0, 0), (-1, -1), "TOP"),
                               ("LEFTPADDING", (0, 0), (-1, -1), 14), ("RIGHTPADDING", (0, 0), (-1, -1), 12), ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                               ("TOPPADDING", (0, 0), (-1, 0), 9), ("BOTTOMPADDING", (0, n - 1), (-1, n - 1), 9)]))
        t.spaceBefore = 4; t.spaceAfter = 12; return [t]

    def tiles(items, W):
        out = []; per = 4 if W > 300 else 2
        for k in range(0, len(items), per):
            grp = items[k:k + per]; n = len(grp); gap = 10.0; tw = (W - gap * (n - 1)) / n; iw = tw - 16
            cells = []; widths = []; cmds = [("VALIGN", (0, 0), (-1, -1), "MIDDLE"), ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                                             ("TOPPADDING", (0, 0), (-1, -1), 11), ("BOTTOMPADDING", (0, 0), (-1, -1), 11)]
            for j, (val, lab) in enumerate(grp):
                raw = re.sub(r"[*`]", "", clean(val)); fs = 28.0
                while fs > 13 and pdfmetrics.stringWidth(raw, FB, fs) > iw: fs -= 1
                c = [Paragraph(inl(val), ParagraphStyle("zv", fontName=FB, fontSize=fs, leading=fs * 1.2, textColor=acct, alignment=1))]
                if lab: c.append(Paragraph(inl(lab), ParagraphStyle("zl", fontName=F, fontSize=9, leading=12, textColor=colors.HexColor("#55555c"), alignment=1, spaceBefore=3)))
                x = len(cells); cells.append(c); widths.append(tw)
                cmds += [("BACKGROUND", (x, 0), (x, 0), tilebg), ("LINEABOVE", (x, 0), (x, 0), 2.5, acc),
                         ("LEFTPADDING", (x, 0), (x, 0), 8), ("RIGHTPADDING", (x, 0), (x, 0), 8)]
                if j < n - 1: cells.append(""); widths.append(gap)
            t = Table([cells], colWidths=widths); t.setStyle(TableStyle(cmds)); t.spaceBefore = 4; t.spaceAfter = 12; out.append(t)
        return out

    def spalten(cols, W, depth):
        n = len(cols); gap = 16.0; cw = (W - gap * (n - 1)) / n; chunks = []
        for c in cols:
            ch = [[]]; h = 0
            for f in build(c, cw, True, depth + 1):
                for p in pieces(f, cw):
                    ph = fh(p, cw)
                    if ch[-1] and h + ph > MAXH: ch.append([]); h = 0
                    ch[-1].append(p); h += ph
            chunks.append(ch)
        data = [[(chunks[j][r] if r < len(chunks[j]) and chunks[j][r] else "") for j in range(n)] for r in range(max(len(c) for c in chunks))]
        t = Table(data, colWidths=[cw + gap] * (n - 1) + [cw])
        t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), gap), ("RIGHTPADDING", (-1, 0), (-1, -1), 0),
                               ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 4)]))
        t.spaceBefore = 2; t.spaceAfter = 8; return t

    # ---- Diagramme ----
    PAL = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
    INK2 = colors.HexColor("#52514e"); GRID = colors.HexColor("#e1e0d9"); BASE = colors.HexColor("#c3c2b7")
    def num(c):
        s = re.sub(r"[^\d,.\-]", "", c.replace("−", "-")).strip(".,")
        if not re.search(r"\d", s): return None
        if "," in s and "." in s: s = s.replace(".", "").replace(",", ".") if s.rfind(",") > s.rfind(".") else s.replace(",", "")
        elif "," in s: s = s.replace(",", ".")
        elif re.fullmatch(r"-?\d{1,3}(\.\d{3})+", s): s = s.replace(".", "")
        try: return float(s)
        except Exception: return None
    def fmt(v, unit=""):
        s = "{:,.0f}".format(v) if abs(v - round(v)) < 1e-9 else "{:,.2f}".format(v).rstrip("0").rstrip(".")
        s = s.replace(",", "X").replace(".", ",").replace("X", ".")
        return s + (" " + unit if unit else "")
    def sw(t, size=7.5, font=None): return pdfmetrics.stringWidth(t, font or F, size)
    def fit(t, maxw, size=7.5):
        if sw(t, size) <= maxw: return t
        while len(t) > 1 and sw(t + "…", size) > maxw: t = t[:-1]
        return t + "…"
    def diagramm(arg, body, W):
        from reportlab.graphics.shapes import Drawing, Rect, Line, String, PolyLine, Circle, Wedge
        TYP = {"balken": "balken", "saeulen": "balken", "säulen": "balken", "saeule": "balken", "bar": "balken", "linie": "linie", "linien": "linie", "line": "linie", "verlauf": "linie",
               "kreis": "kreis", "torte": "kreis", "kuchen": "kreis", "pie": "kreis", "quer": "quer", "querbalken": "quer", "liegend": "quer"}
        toks = arg.split(None, 1); typ = TYP.get(toks[0].lower().strip(":,")) if toks else None
        ttl = (toks[1] if len(toks) > 1 else "") if typ else arg
        typ = typ or "balken"; names = []; rows = []; unit = ""
        for b in body:
            s = b.strip().lstrip("-*• ").strip()
            if not s or re.fullmatch(r"[|\s:\-]+", s): continue
            cells = [c.strip() for c in s.strip("|").split("|")]
            if len(cells) < 2:
                m = re.match(r"^(.*?)[:=]\s*([^:=]+)$", s)
                if not m: continue
                cells = [m.group(1).strip(), m.group(2).strip()]
            vals = [num(c) for c in cells[1:]]
            if all(v is None for v in vals):
                if not rows and not names: names = cells[1:]
                continue
            if not unit:
                u = re.sub(r"[\d.,\s+\-−]", "", next(c for c, v in zip(cells[1:], vals) if v is not None))
                if 0 < len(u) <= 4: unit = clean(u)
            rows.append((clean(re.sub(r"[*`]", "", cells[0])), [v if v is not None else 0.0 for v in vals]))
        isyear = lambda v: v == int(v) and 1900 <= v <= 2100
        if len(rows) > 1 and not names and len(rows[0][1]) > 1 and all(isyear(v) for v in rows[0][1]) and any(not isyear(v) for r in rows[1:] for v in r[1]):
            names = ["%d" % v for v in rows[0][1]]; rows = rows[1:]
        if not rows: return [note("Diagramm ohne Daten")]
        ns = min(max(len(r[1]) for r in rows), 6); rows = [(l, (v + [0.0] * ns)[:ns]) for l, v in rows]
        names = [clean(re.sub(r"[*`]", "", x)) for x in names][:ns]; names += ["Reihe %d" % (k + 1) for k in range(len(names), ns)]
        if typ == "quer" and (ns > 1 or any(v < 0 for _, vs in rows for v in vs)): typ = "balken"
        S = lambda x, y, t, a="start", size=7.5, col=INK2, font=None: String(x, y, t, fontName=font or F, fontSize=size, fillColor=col, textAnchor=a)
        hx = colors.HexColor
        if typ == "kreis":
            vals = [(l, vs[0]) for l, vs in rows if vs[0] > 0]
            if not vals: return [note("Diagramm ohne Daten")]
            if len(vals) > 6:
                keep = sorted(vals, key=lambda x: -x[1])[:5]; other = sum(v for x in vals if x not in keep for v in [x[1]])
                vals = [x for x in vals if x in keep] + [("Sonstige", other)]
            tot = sum(v for _, v in vals); n = len(vals); h = max(n * 17 + 12.0, min(W * 0.42, 170.0)); r = min(h - 8, W * 0.42) / 2.0
            d = Drawing(W, h); cx = r + 2; cy = h / 2.0; a = 90.0; lx = cx + r + 18; ly = cy + n * 17 / 2.0 - 12; rw = min(W - 2, lx + 210)
            for k, (l, v) in enumerate(vals):
                ang = 360.0 * v / tot
                if n == 1: d.add(Circle(cx, cy, r, fillColor=hx(PAL[k]), strokeColor=None))
                else: d.add(Wedge(cx, cy, r, a - ang, a, fillColor=hx(PAL[k]), strokeColor=colors.white, strokeWidth=1.5))
                a -= ang; y = ly - k * 17; pc = fmt(round(100.0 * v / tot, 1)) + " %"; vt = pc if unit == "%" and abs(tot - 100) < 0.6 else "%s (%s)" % (fmt(v, unit), pc)
                d.add(Rect(lx, y, 8, 8, rx=2, ry=2, fillColor=hx(PAL[k]), strokeColor=None))
                d.add(S(lx + 13, y + 1, fit(l, rw - lx - 13 - sw(vt, 8) - 10, 8), size=8, col=ink)); d.add(S(rw, y + 1, vt, "end", 8))
        elif typ == "quer":
            rows = rows[:20]; n = len(rows); rh = 20.0; bh = 12.0; h = n * rh + 6
            lw = min(max(sw(l, 8) for l, _ in rows) + 10, W * 0.38); vw = max(sw(fmt(vs[0], unit), 8) for _, vs in rows) + 8
            d = Drawing(W, h); x0 = lw; pw = W - lw - vw; vmax = max(vs[0] for _, vs in rows) or 1.0
            for i, (l, vs) in enumerate(rows):
                y = h - 3 - (i + 1) * rh + (rh - bh) / 2.0; wv = pw * vs[0] / vmax; rr = min(4, wv)
                d.add(S(lw - 7, y + 3, fit(l, lw - 10, 8), "end", 8, ink))
                if wv > 0:
                    d.add(Rect(x0, y, wv, bh, rx=rr, ry=rr, fillColor=acc, strokeColor=None))
                    if wv > rr: d.add(Rect(x0, y, wv - rr, bh, fillColor=acc, strokeColor=None))
                d.add(S(x0 + wv + 5, y + 3, fmt(vs[0], unit), "start", 8, ink))
            d.add(Line(x0, 1, x0, h - 1, strokeColor=BASE, strokeWidth=0.8))
        else:
            rows = rows[:30]; n = len(rows); allv = [v for _, vs in rows for v in vs]; lo = min(0.0, min(allv)); hi = max(0.0, max(allv))
            if hi <= lo: hi = lo + 1.0
            raw = (hi - lo) / 4.0; mag = 10 ** math.floor(math.log10(raw)); step = next(q * mag for q in (1, 2, 2.5, 5, 10) if q * mag >= raw - 1e-12)
            t0 = math.floor(lo / step + 1e-9) * step; tk = [t0 + k * step for k in range(int(round((math.ceil(hi / step - 1e-9) * step - t0) / step)) + 1)]
            lab = [fmt(t) for t in tk]; ml = max(sw(x) for x in lab) + 8
            cols = [acc] if ns == 1 else [hx(c) for c in PAL]
            Yf = lambda v, y0, ph: y0 + (v - tk[0]) / (tk[-1] - tk[0]) * ph
            lrows = 0
            if ns > 1:
                x = 0.0; lrows = 1
                for nm in names:
                    tw = sw(nm, 8) + 26
                    if x + tw > W and x > 0: x = 0.0; lrows += 1
                    x += tw
            h = min(max(150.0, W * 0.5), 230.0) + lrows * 13; mt = 13 + lrows * 13 + (4 if lrows else 0); mb = 20.0
            ends = typ == "linie" and ns <= 4 and n > 1
            mr = (max(sw(fmt(v)) for v in rows[-1][1]) + 12) if ends else 6.0
            d = Drawing(W, h); x0 = ml; y0 = mb; pw = W - ml - mr; ph = h - mt - mb; Y = lambda v: Yf(v, y0, ph); band = pw / n
            if ns > 1:
                x = 0.0; y = h - 9
                for k, nm in enumerate(names):
                    tw = sw(nm, 8) + 26
                    if x + tw > W and x > 0: x = 0.0; y -= 13
                    d.add(Rect(x, y, 8, 8, rx=2, ry=2, fillColor=cols[k], strokeColor=None)); d.add(S(x + 12, y + 1, nm, size=8)); x += tw
            for t, s in zip(tk, lab):
                z = abs(t) < 1e-9
                d.add(Line(x0, Y(t), x0 + pw, Y(t), strokeColor=BASE if z else GRID, strokeWidth=0.8 if z else 0.5)); d.add(S(x0 - 5, Y(t) - 2.6, s, "end"))
            every = max(1, int(math.ceil(n / max(1.0, math.floor(pw / 38.0)))))
            for i, (l, _) in enumerate(rows):
                if i % every == 0: d.add(S(x0 + i * band + band / 2.0, y0 - 11, fit(l, band * every - 3), "middle"))
            if typ == "balken":
                bw = max(1.5, min(24.0, (band * 0.72 - 2 * (ns - 1)) / ns)); gw = bw * ns + 2 * (ns - 1)
                for i, (l, vs) in enumerate(rows):
                    for k, v in enumerate(vs):
                        x = x0 + i * band + (band - gw) / 2.0 + k * (bw + 2); ya, yb = Y(0), Y(v); yl, yh = min(ya, yb), max(ya, yb); hh = yh - yl
                        if hh > 0:
                            rr = min(4, bw / 2.0, hh)
                            d.add(Rect(x, yl, bw, hh, rx=rr, ry=rr, fillColor=cols[k], strokeColor=None))
                            if hh > rr: d.add(Rect(x, yl if v >= 0 else yl + rr, bw, hh - rr, fillColor=cols[k], strokeColor=None))
                        if ns == 1 and n <= 14 and sw(fmt(v)) <= band - 2:
                            d.add(S(x + bw / 2.0, yh + 3, fmt(v), "middle", col=ink))
            else:
                ey = sorted(Y(v) for v in rows[-1][1])
                if ends and any(b - a < 9 for a, b in zip(ey, ey[1:])): ends = False
                for k in range(ns):
                    pts = []
                    for i, (_, vs) in enumerate(rows): pts += [x0 + i * band + band / 2.0, Y(vs[k])]
                    if n > 1: d.add(PolyLine(pts, strokeColor=cols[k], strokeWidth=2, strokeLineJoin=1, strokeLineCap=1))
                    if n <= 24:
                        for q in range(0, len(pts), 2): d.add(Circle(pts[q], pts[q + 1], 3.4, fillColor=cols[k], strokeColor=colors.white, strokeWidth=1.5))
                    if ends: d.add(S(pts[-2] + 8, pts[-1] - 2.6, fmt(rows[-1][1][k]), "start", col=ink))
            if unit: ttl = (ttl + " (in %s)" % unit) if ttl else "in %s" % unit
        cell = [d]
        if ttl: cell.insert(0, Paragraph(inl(ttl), ParagraphStyle("dt", fontName=FB, fontSize=10.5, leading=14, textColor=ink, spaceAfter=7)))
        t = Table([[cell]], colWidths=[W])
        t.setStyle(TableStyle([("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 0)]))
        t.spaceBefore = 6; t.spaceAfter = 14; return [t]

    # ---- Bloecke einlesen ----
    def take(lines, i, mode):
        body = []; inbox = False; fence = False; depth = 0
        while i < len(lines):
            s = lines[i].strip()
            if s.startswith("```"): fence = not fence
            elif not fence:
                m = OPEN.match(s)
                if NEST:
                    if is_close(s):
                        if depth == 0: return body, i + 1
                        depth -= 1
                    elif m and needs_close(kind_of(m), m.group(2).strip()): depth += 1
                elif is_close(s):
                    if mode == "spalten" and inbox: inbox = False
                    else: return body, i + 1
                elif mode != "spalten" and (m or is_sep(s)): return body, i
                elif mode == "spalten" and m:
                    k = kind_of(m)
                    if k == "spalten": return body, i
                    if needs_close(k, m.group(2).strip()): inbox = True
                elif mode == "spalten" and is_sep(s): inbox = False
            body.append(lines[i]); i += 1
        return body, i
    def split_cols(body):
        cols = [[]]; fence = False; depth = 0
        for b in body:
            s = b.strip()
            if s.startswith("```"): fence = not fence
            elif not fence and NEST:
                m = OPEN.match(s)
                if is_close(s): depth = max(0, depth - 1)
                elif m and needs_close(kind_of(m), m.group(2).strip()): depth += 1
            if not fence and depth == 0 and is_sep(s): cols.append([])
            else: cols[-1].append(b)
        cols = [c for c in cols if any(x.strip() for x in c)]
        if len(cols) > 3: cols = cols[:2] + [sum(cols[2:], [])]
        return cols

    def build(lines, W, inner=False, depth=0):
        nonlocal first_h1, kopf_t
        lines = list(lines); story = []; i = 0; para = []; zs = []
        def flushp():
            if para: story.append(Paragraph(inl(" ".join(x.strip() for x in para)), st["p"])); para.clear()
        def flush():
            flushp()
            if zs: story.extend(tiles(list(zs), W)); zs.clear()
        while i < len(lines):
            ln = lines[i]; sl = ln.strip()
            if sl.startswith("```"):
                flush(); i += 1; code = []
                while i < len(lines) and not lines[i].strip().startswith("```"): code.append(lines[i]); i += 1
                story.append(XPreformatted(escape(clean("\n".join(code))), st["code"])); i += 1; continue
            if not sl: flushp(); i += 1; continue
            if is_close(sl) or is_sep(sl): flush(); i += 1; continue
            m = OPEN.match(sl)
            if m:
                k = kind_of(m); arg = m.group(2).strip()
                if k == "zahl":
                    flushp(); v, _, l = arg.partition("|"); i += 1
                    if v.strip(): zs.append((v.strip(), l.strip()))
                    continue
                flush()
                if k == "zahlen":
                    body, i = take(lines, i + 1, "box")
                    for b in body:
                        v, _, l = b.strip().lstrip("-*• ").partition("|")
                        if v.strip(): zs.append((v.strip(), l.strip()))
                    flush(); continue
                if k == "seite":
                    i += 1
                    if not inner and story and not isinstance(story[-1], PageBreak): story.append(PageBreak())
                    continue
                if k == "inhalt":
                    i += 1
                    if not inner and has_toc:
                        from reportlab.platypus.tableofcontents import TableOfContents
                        toc = TableOfContents(); toc.dotsMinLevel = 0
                        toc.levelStyles = [ParagraphStyle("t1", fontName=FB, fontSize=10.5, leading=15, textColor=ink, spaceBefore=5),
                                           ParagraphStyle("t2", fontName=F, fontSize=10, leading=14, textColor=ink, leftIndent=14),
                                           ParagraphStyle("t3", fontName=F, fontSize=9.5, leading=13, textColor=colors.HexColor("#55555c"), leftIndent=28)]
                        story += [Paragraph(inl(arg or "Inhalt"), st["h2"]), toc, Spacer(1, 12)]
                    continue
                if k == "bild":
                    i += 1; story += bild(arg, W, inner); continue
                if k == "diagramm":
                    body, i = take(lines, i + 1, "box")
                    try: story += diagramm(arg, body, W)
                    except Exception as e: print("make_pdf: Diagramm-Fehler:", type(e).__name__, str(e)[:160], flush=True); story.append(note("Diagramm konnte nicht erzeugt werden"))
                    continue
                if k == "kopf":
                    if arg: t, _, sub = arg.partition("|"); i += 1
                    else:
                        body, i = take(lines, i + 1, "box"); body = [b.strip() for b in body if b.strip()]
                        t = body[0] if body else ""; sub = " ".join(body[1:])
                    t = t.strip().lstrip("#").strip(); sub = sub.strip()
                    if t:
                        if kopf_t is None: kopf_t = t
                        if inner:
                            story.append(Paragraph(inl(t), st["h1"]))
                            if sub: story.append(Paragraph(inl(sub), st["p"]))
                        else: kopf_top[0] = True; story.append(Kopf(t, sub, not story or isinstance(story[-1], PageBreak)))
                    continue
                if k == "spalten":
                    body, i = take(lines, i + 1, "spalten"); cols = split_cols(body)
                    if len(cols) < 2 or (W - 16.0 * (len(cols) - 1)) / len(cols) < 90 or (inner and not NEST) or depth > 10:
                        for c in cols: story += build(c, W, True, depth + 1)
                    else: story.append(spalten(cols, W, depth))
                    continue
                body, i = take(lines, i + 1, "box"); story += box(k, arg, body, W, depth); continue
            m = re.match(r"^(#{1,3})\s+(.*)$", sl)
            if m:
                flush(); lv = len(m.group(1)); i += 1
                if lv == 1 and first_h1 is None: first_h1 = m.group(2)
                if lv == 1 and kopf_t and m.group(2).strip().lower() == kopf_t.lower(): continue
                story.append(heading(m.group(2), lv)); continue
            if re.fullmatch(r"[-*_]{3,}", sl):
                flush(); story.append(HRFlowable(width="100%", thickness=0.6, color=colors.HexColor("#c9c9d0"), spaceBefore=4, spaceAfter=8)); i += 1; continue
            if sl.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*:?-{2,}", lines[i + 1].strip()):
                flush(); rows = []
                while i < len(lines) and lines[i].strip().startswith("|") and not is_sep(lines[i].strip()):
                    if not re.match(r"^\|?\s*:?-{2,}", lines[i].strip()): rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
                    i += 1
                n = max(len(r) for r in rows); rows = [r + [""] * (n - len(r)) for r in rows]
                data = [[Paragraph(inl(c), st["cellh"] if k == 0 else st["cell"]) for c in r] for k, r in enumerate(rows)]
                t = Table(data, colWidths=[(W if inner else W + 12) / n] * n, repeatRows=1)
                t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, 0), acc), ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#c9c9d0")),
                                       ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f6f6f8")]), ("VALIGN", (0, 0), (-1, -1), "TOP"),
                                       ("LEFTPADDING", (0, 0), (-1, -1), 5), ("RIGHTPADDING", (0, 0), (-1, -1), 5), ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4)]))
                story += [t, Spacer(1, 10)]; continue
            m = re.match(r"^(\s*)([-*•]|\d+[.)])\s+(.*)$", ln)
            if m:
                flush(); ind = min(len(m.group(1).replace("\t", "    ")) // 2, 3) * 12; b = "•" if m.group(2) in "-*•" else m.group(2)
                ls = ParagraphStyle("li2", parent=st["li"], leftIndent=16 + ind, bulletIndent=4 + ind)
                story.append(Paragraph(inl(m.group(3)), ls, bulletText=b)); i += 1; continue
            if sl.startswith(">"):
                flush(); story.append(Paragraph(inl(sl.lstrip("> ")), st["q"])); i += 1; continue
            if zs: flush()
            para.append(ln); i += 1
        flush()
        return story

    def plain(lines):
        out = []
        for ln in lines:
            s = ln.strip(); m = OPEN.match(s)
            if is_close(s) or is_sep(s): out.append("")
            elif m:
                k = kind_of(m); a = m.group(2).strip()
                if k == "kopf": out += ["# " + a.partition("|")[0].strip(), a.partition("|")[2].strip(), ""] if a else [""]
                elif k == "zahl": out += ["**%s** %s" % (a.partition("|")[0].strip(), a.partition("|")[2].strip()), ""]
                elif k in ("spalten", "zahlen", "seite", "inhalt", "bild"): out.append("")
                elif k == "diagramm": out += ["**%s**" % (a.split(None, 1)[1] if len(a.split(None, 1)) > 1 else "Diagramm"), ""]
                else: out += ["**%s**" % (a or (BOX.get(k) or (k.capitalize(),))[0]), ""]
            else: out.append(ln)
        return out

    ftxt = clean(re.sub(r"[*`]", "", cfg["fuss"])) if cfg["fuss"] not in ("", "1") else ""
    def footer(cv, doc):
        cv.saveState(); cv.setFont(F, 8.5); cv.setFillColor(colors.HexColor("#777777"))
        if ftxt:
            cv.drawString(2 * cm + 6, 1.1 * cm, fit(ftxt, PW - 4 * cm - 80, 8.5)); cv.drawRightString(PW - 2 * cm - 6, 1.1 * cm, "Seite %d" % doc.page)
        else: cv.drawCentredString(PW / 2, 1.1 * cm, "Seite %d" % doc.page)
        cv.restoreState()
    for attempt in (0, 1):
        first_h1 = None; kopf_t = None; hn[0] = 0; kopf_top[0] = False
        if attempt: has_toc = False; NEST = False
        story = build(src if attempt == 0 else plain(src), W0)
        if logo and not kopf_top[0]:
            try:
                logo[0].seek(0); lh = 46.0; lw = logo[1] * lh / logo[2]
                if lw > 150: lh *= 150 / lw; lw = 150.0
                im = RLImage(logo[0], width=lw, height=lh); im.hAlign = "RIGHT"; im.spaceAfter = 8; story.insert(0, im)
            except Exception: pass
        ttl = (title or kopf_t or first_h1 or "Dokument")
        doc = SimpleDocTemplate(path, pagesize=PS, leftMargin=2 * cm, rightMargin=2 * cm, topMargin=2 * cm, bottomMargin=2 * cm, title=clean(ttl), author="")
        docref[0] = doc
        try:
            if has_toc and not attempt: doc.multiBuild(story or [Paragraph(" ", st["p"])], onFirstPage=footer, onLaterPages=footer)
            else: doc.build(story or [Paragraph(" ", st["p"])], onFirstPage=footer, onLaterPages=footer)
            break
        except Exception as e:
            if attempt: raise
            print("make_pdf: Layout-Fallback ohne Kaesten/Spalten:", type(e).__name__, str(e)[:200], flush=True)

def tool_file(args):
    name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(str(args.get("filename", "datei.txt"))))[:80].strip(".") or "datei.txt"
    content = args.get("content")
    if not isinstance(content, str) or not content: raise ValueError("content fehlt")
    fid = uuid.uuid4().hex[:6]
    if name.lower().endswith(".pdf"):
        make_pdf(content, os.path.join(FILES, fid + "__" + name), str(args.get("title", "")))
    else:
        open(os.path.join(FILES, fid + "__" + name), "w", encoding="utf-8").write(content)
    return fid, name

def save_prompt(i, p):
    try: open(img_path(i) + ".txt", "w").write(p)
    except Exception: pass

def load_prompt(i):
    try: return open(img_path(i) + ".txt").read()
    except Exception: return "(Prompt nicht gespeichert)"

def tool_generate(args, opts=None):
    opts = opts or {}
    prompt = str(args.get("prompt", "")).strip()
    if not prompt: raise ValueError("prompt fehlt")
    w, h = snap16(args.get("width")), snap16(args.get("height"))
    if opts.get("fmt") in SIZES: w, h = SIZES[opts["fmt"]]
    up = bool(args.get("upscale")) or bool(opts.get("up"))
    try: n = max(1, min(4, int(opts.get("n") or 1)))
    except Exception: n = 1
    ids = []
    for _ in range(n):
        g, o = graph_t2i(prompt, w, h, up, random.randint(0, 2**50), {"off": 0.0, "low": 0.4}.get(str(opts.get("lora") or ""), 0.8))
        with gpu_lock: data = run_comfy(g, o)
        i = new_id("gen"); save_img(i, data); save_prompt(i, prompt); ids.append(i)
    return ids

def tool_edit(args, opts=None):
    prompt = str(args.get("prompt", "")).strip()
    ids = args.get("image_ids") or []
    if isinstance(ids, str): ids = [ids]
    ids = [x for x in ids if isinstance(x, str)][:2]
    if not prompt or not ids: raise ValueError("prompt oder image_ids fehlen")
    for x in ids:
        if not os.path.exists(img_path(x)): raise ValueError("unbekannte Bild-ID " + x)
    with gpu_lock:
        names = [comfy_upload(x) for x in ids]
        lo = str((opts or {}).get("lora") or "")
        g, o = graph_edit(prompt, names, random.randint(0, 2**50), 0.0 if (lo == "off" or not EDIT_LORA) else (0.4 if lo == "low" else 0.8))
        data = run_comfy(g, o)
    i = new_id("gen"); save_img(i, data); save_prompt(i, prompt); return [i]


# ---------------- Dateien analysieren ----------------
def decode_text(data):
    if b"\x00" in data[:8192]: return None
    for enc in ("utf-8", "utf-8-sig"):
        try: return data.decode(enc)
        except Exception: pass
    t = data.decode("latin-1")
    pr = sum(1 for ch in t[:4000] if ch.isprintable() or ch in "\n\r\t")
    return t if pr / max(1, len(t[:4000])) > 0.92 else None

def xml_text(x):
    x = re.sub(r"</w:p>|</a:p>|<w:br/>|<text:p[^>]*>|</text:p>", "\n", x)
    x = re.sub(r"<w:tab/>", "\t", x)
    return htmlmod.unescape(re.sub(r"<[^>]+>", "", x)).strip()

def pdf_text(data):
    if shutil.which("pdftotext"):
        try:
            r = subprocess.run(["pdftotext", "-layout", "-", "-"], input=data, capture_output=True, timeout=90)
            t = r.stdout.decode("utf-8", "ignore")
            if t.strip(): return t
        except Exception: pass
    try:
        import pypdf
        rd = pypdf.PdfReader(io.BytesIO(data))
        t = "\n\n".join(f"--- Seite {i+1} ---\n" + (p.extract_text() or "") for i, p in enumerate(rd.pages))
        if t.strip(): return t
    except Exception as e:
        return f"(PDF konnte nicht gelesen werden: {type(e).__name__}. Evtl. fehlt pypdf.)"
    return "(Das PDF enthaelt keinen auslesbaren Text, vermutlich ein Scan oder Bild-PDF.)"

def zip_read(z, name):
    try: return z.read(name).decode("utf-8", "ignore")
    except Exception: return ""

def office_text(z, ext):
    names = z.namelist()
    if ext in ("docx", "docm", "dotx"):
        return xml_text(zip_read(z, "word/document.xml"))
    if ext in ("pptx", "pptm"):
        sl = sorted([n for n in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)], key=lambda n: int(re.findall(r"\d+", n)[0]))
        return "\n\n".join(f"--- Folie {i+1} ---\n" + xml_text(zip_read(z, n)) for i, n in enumerate(sl))
    if ext in ("xlsx", "xlsm"):
        ss = [xml_text(re.sub(r"</t>", " </t>", m)) for m in re.findall(r"<si>(.*?)</si>", zip_read(z, "xl/sharedStrings.xml"), re.S)]
        sh = sorted([n for n in names if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n)], key=lambda n: int(re.findall(r"\d+", n)[0]))
        out = []
        for i, n in enumerate(sh):
            out.append(f"--- Blatt {i+1} ---")
            for rn, row in enumerate(re.findall(r"<row[^>]*>(.*?)</row>", zip_read(z, n), re.S)):
                if rn >= 800: out.append("[... weitere Zeilen ausgelassen ...]"); break
                cells = []
                for attrs, inner in re.findall(r"<c([^>]*?)(?:/>|>(.*?)</c>)", row, re.S):
                    v = re.search(r"<v>(.*?)</v>", inner or "", re.S); t = re.search(r't="(\w+)"', attrs)
                    if t and t.group(1) == "s" and v:
                        try: cells.append(ss[int(v.group(1))])
                        except Exception: cells.append("")
                    elif t and t.group(1) == "inlineStr": cells.append(xml_text(inner or ""))
                    else: cells.append(htmlmod.unescape(v.group(1)) if v else "")
                out.append("\t".join(cells))
        return "\n".join(out)
    if ext in ("odt", "ods", "odp"):
        return xml_text(zip_read(z, "content.xml"))
    return None

def zip_summary(z, name):
    infos = [i for i in z.infolist() if not i.is_dir()]
    out = [f"Archiv {name}: {len(infos)} Dateien", "Inhalt:"]
    for i in infos[:300]: out.append(f"  {i.filename}  ({i.file_size} Bytes)")
    if len(infos) > 300: out.append(f"  ... und {len(infos) - 300} weitere")
    budget = 60000
    for i in infos:
        if budget <= 0: break
        if i.file_size > 300000 or i.file_size == 0: continue
        try: t = decode_text(z.read(i.filename))
        except Exception: t = None
        if t is None: continue
        t = cut(t, min(budget, 12000)); budget -= len(t)
        out.append(f"\n=== {i.filename} ===\n{t}")
    return "\n".join(out)

def magic_kind(d):
    for sig, k in ((b"\x89PNG", "PNG-Bild"), (b"\xff\xd8\xff", "JPEG-Bild"), (b"GIF8", "GIF-Bild"), (b"%PDF", "PDF"), (b"PK\x03\x04", "ZIP-Archiv"),
                   (b"\x7fELF", "ELF-Programm"), (b"MZ", "Windows-Programm (EXE/DLL)"), (b"\xcf\xfa\xed\xfe", "Mach-O (macOS/iOS)"), (b"\xca\xfe\xba\xbe", "Mach-O/Java-Class"),
                   (b"\x1f\x8b", "gzip"), (b"SQLite format 3", "SQLite-Datenbank"), (b"bplist", "Binaere Plist")):
        if d.startswith(sig): return k
    return "unbekanntes Binaerformat"

def sqlite_text(data):
    p = os.path.join(DOCS, "tmp_" + uuid.uuid4().hex[:6] + ".db"); open(p, "wb").write(data)
    try:
        c = sqlite3.connect(p); out = []
        for n, sql in c.execute("select name, sql from sqlite_master where type in ('table','view')"):
            out.append(f"-- {n}\n{sql}")
            try:
                rows = c.execute(f'select * from "{n}" limit 8').fetchall()
                out.extend("   " + repr(r)[:300] for r in rows)
            except Exception: pass
        c.close(); return "\n".join(out) or "(leere Datenbank)"
    finally:
        try: os.remove(p)
        except Exception: pass

def extract_text(name, data):
    ext = name.lower().rsplit(".", 1)[-1] if "." in name else ""
    if data.startswith(b"%PDF") or ext == "pdf": return "PDF", pdf_text(data)
    if data.startswith(b"SQLite format 3"): return "SQLite", sqlite_text(data)
    if data.startswith(b"bplist") or ext == "plist" and data[:5] != b"<?xml":
        try: return "Plist", json.dumps(plistlib.loads(data), indent=1, default=str, ensure_ascii=False)
        except Exception: pass
    if zipfile.is_zipfile(io.BytesIO(data)):
        z = zipfile.ZipFile(io.BytesIO(data))
        t = office_text(z, ext)
        if t is not None: return "Office", t
        return "Archiv", zip_summary(z, name)
    if ext in ("gz", "tgz", "tar", "bz2", "xz"):
        try:
            tf = tarfile.open(fileobj=io.BytesIO(data)); out = [f"TAR-Archiv {name}:"]
            for m in tf.getmembers()[:300]: out.append(f"  {m.name} ({m.size} Bytes)")
            budget = 40000
            for m in tf.getmembers():
                if budget <= 0: break
                if not m.isfile() or m.size > 300000: continue
                t = decode_text(tf.extractfile(m).read())
                if t: t = cut(t, min(budget, 10000)); budget -= len(t); out.append(f"\n=== {m.name} ===\n{t}")
            return "Archiv", "\n".join(out)
        except Exception: pass
    t = decode_text(data)
    if t is not None: return "Text", t
    strs = re.findall(rb"[\x20-\x7e]{6,}", data)[:80]
    return "Binaer", (f"Binaerdatei: {name}\nGroesse: {len(data)} Bytes\nErkannter Typ: {magic_kind(data)}\nErste Bytes (hex): {data[:24].hex(' ')}\n"
                      "Lesbare Zeichenketten (Auszug):\n" + "\n".join(x.decode("ascii") for x in strs))[:8000]

def mem_path(): return os.path.join(STORE, "gedaechtnis.txt")

def load_memory():
    try: return open(mem_path(), encoding="utf-8").read().strip()
    except Exception: return ""

def save_memory(text):
    open(mem_path(), "w", encoding="utf-8").write(text.strip()[:4000])

def save_doc(name, data):
    kind, text = extract_text(name, data)
    did = new_id("doc"); open(os.path.join(DOCS, did + ".txt"), "w", encoding="utf-8").write(text)
    return {"id": did, "name": name, "chars": len(text), "kind": kind}

# ---------------- Chats / Galerie ----------------
def chat_file(i):
    if not re.fullmatch(r"c_[0-9a-f]{8}", str(i)): raise ValueError("ungueltige Chat-ID")
    return os.path.join(CHATS, i + ".json")

def chats_list():
    out = []
    for f in os.listdir(CHATS):
        if not f.endswith(".json"): continue
        p = os.path.join(CHATS, f)
        try:
            d = json.load(open(p, encoding="utf-8")); out.append({"id": f[:-5], "title": d.get("title") or "Chat", "t": int(os.path.getmtime(p))})
        except Exception: pass
    return sorted(out, key=lambda x: -x["t"])[:200]

def gallery_list():
    out = []
    for f in os.listdir(STORE):
        if f.startswith("gen_") and f.endswith(".bin"):
            i = f[:-4]; p = os.path.join(STORE, f)
            out.append({"id": i, "t": int(os.path.getmtime(p)), "prompt": load_prompt(i)[:240]})
    return sorted(out, key=lambda x: -x["t"])[:400]

# ---------------- LLM-Schleife ----------------
BADTAG = re.compile(r"\[(?:Erzeugte|Angeh\w+|Erstellte)[^\]\n]{0,15}(?:Bilder|Dateien)[^\]]*\]\s*")

def doc_text(did):
    if not re.fullmatch(r"doc_[0-9a-f]{6}", str(did)): return ""
    try: return open(os.path.join(DOCS, did + ".txt"), encoding="utf-8").read()
    except Exception: return ""

def cut(t, cap):
    if len(t) <= cap: return t
    head = int(cap * 0.7); tail = cap - head
    return t[:head] + f"\n[... gekuerzt: {len(t) - cap} Zeichen ausgelassen ...]\n" + t[-tail:]

def build_messages(client_msgs, fast=False, opts=None):
    out = [{"role": "system", "content": SYSTEM}]
    mem = load_memory()
    if mem:
        out[0]["content"] += (" LANGZEIT-GEDAECHTNIS (vom Nutzer freigegebene, ueber Chats erhaltene Notizen zu ihm und seinen Projekten; "
                              "nutze sie, ohne sie zu wiederholen):\n" + mem)
    if opts and (opts.get("fmt") in SIZES or opts.get("n") or opts.get("up")):
        out[0]["content"] += (" HINWEIS: Der Nutzer hat in der Oberflaeche Bildoptionen eingestellt (Format, Anzahl, Hochskalieren). "
                              "Rufe generate_image trotzdem nur EINMAL auf; Groesse und Anzahl werden automatisch angewendet.")
    doc_idx = [k for k, m in enumerate(client_msgs) if m.get("role") == "user" and m.get("docs")][-2:]
    total_cap = 18000 if fast else 45000; per_cap = 15000 if fast else 30000
    budget = total_cap; doc_part = {}
    for k in reversed(doc_idx):
        parts = []
        for d in client_msgs[k]["docs"]:
            t = doc_text(d.get("id"))
            cap = max(0, min(per_cap, budget))
            body = cut(t, cap) if cap > 0 else "(nicht mehr im Kontext, bitte erneut hochladen)"
            budget -= min(len(t), cap)
            parts.append(f"\n\n[Datei: {d.get('name','datei')}]\n```\n{body}\n```")
        doc_part[k] = "".join(parts)
    for k, m in enumerate(client_msgs):
        if m.get("role") == "user":
            ids = [im["id"] for im in m.get("images", [])]
            txt = m.get("text", "")
            if ids: txt = "[Angehaengte Bilder: " + ", ".join(ids) + "]\n" + txt
            if m.get("docs"):
                txt += doc_part.get(k) or "".join(f"\n[Frueher angehaengte Datei: {d.get('name','datei')} - Inhalt nicht mehr im Kontext]" for d in m["docs"])
            parts = [{"type": "text", "text": txt or "(kein Text)"}]
            for im in m.get("images", []):
                if im.get("thumb"): parts.append({"type": "image_url", "image_url": {"url": im["thumb"]}})
            out.append({"role": "user", "content": parts if len(parts) > 1 else parts[0]["text"]})
        else:
            txt = BADTAG.sub("", m.get("text", "") or "").strip()
            calls, results = [], []
            for gid in m.get("images") or []:
                cid = "call_" + uuid.uuid4().hex[:6]
                calls.append({"id": cid, "type": "function", "function": {"name": "generate_image", "arguments": json.dumps({"prompt": load_prompt(gid)})}})
                results.append({"role": "tool", "tool_call_id": cid, "content": f"Bild erzeugt, ID {gid}. Es wurde dem Nutzer angezeigt."})
            for fn in m.get("files") or []:
                cid = "call_" + uuid.uuid4().hex[:6]
                calls.append({"id": cid, "type": "function", "function": {"name": "create_file", "arguments": json.dumps({"filename": fn, "content": "(Inhalt in Datei)"})}})
                results.append({"role": "tool", "tool_call_id": cid, "content": f"Datei {fn} erstellt."})
            if calls:
                out.append({"role": "assistant", "content": txt or None, "tool_calls": calls})
                out.extend(results)
            else:
                out.append({"role": "assistant", "content": txt or "(ok)"})
    return out

CODE_RE = re.compile(r"```|\b(code|quellcode|programm\w*|skript\w*|script\w*|funktion\w*|function|bug|debug\w*|kompilier\w*|compil\w*|python|javascript|typescript|html|css|swift|kotlin|java|rust|php|sql|bash|powershell|regex|json|yaml|xml|api|github|docker|traceback|stacktrace|fehlermeldung|syntaxfehler)\b", re.I)
CODE_EXT = (".py", ".js", ".ts", ".jsx", ".tsx", ".html", ".htm", ".css", ".swift", ".kt", ".java", ".c", ".h", ".cpp", ".cs", ".rs", ".go", ".php", ".rb", ".sql", ".sh", ".ps1", ".json", ".yml", ".yaml", ".xml", ".toml", ".ipynb")
def wants_code(client_msgs):
    for m in reversed(client_msgs or []):
        if isinstance(m, dict) and m.get("role") == "user" and not m.get("hidden"):
            if CODE_RE.search(str(m.get("text") or "")): return True
            return any(str(d.get("name", "")).lower().endswith(CODE_EXT) for d in (m.get("docs") or []) if isinstance(d, dict))
    return False

def llm_stream(messages, emit, fast=False, tools=True, think=False, temp=0.7):
    body = {"messages": messages, "stream": True, "temperature": temp,
            "chat_template_kwargs": {"enable_thinking": bool(think)}}
    if tools: body["tools"] = TOOLS
    req = urllib.request.Request((LLM_FAST if fast else LLM) + "/v1/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    text, calls = "", {}; full = ""; told = False
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"): continue
            p = line[5:].strip()
            if p == "[DONE]": break
            try: d = json.loads(p)["choices"][0].get("delta", {})
            except Exception: continue
            if think and d.get("reasoning_content") and not told: told = True; emit({"type": "think"})
            if d.get("content") and think:
                full += d["content"]; vis = re.sub(r"<think>.*?(?:</think>\s*|$)", "", full, flags=re.S)
                if not told and "<think>" in full: told = True; emit({"type": "think"})
                hold = next((k for k in range(min(6, len(vis)), 0, -1) if "<think>".startswith(vis[-k:])), 0)
                out = vis[:len(vis) - hold]
                if len(out) > len(text) and out.startswith(text): emit({"type": "delta", "text": out[len(text):]}); text = out
            elif d.get("content"):
                text += d["content"]; emit({"type": "delta", "text": d["content"]})
            for tc in d.get("tool_calls") or []:
                c = calls.setdefault(tc.get("index", 0), {"id": tc.get("id") or "call_" + uuid.uuid4().hex[:6], "name": "", "args": ""})
                f = tc.get("function", {})
                if f.get("name"): c["name"] += f["name"]
                if f.get("arguments"): c["args"] += f["arguments"]
    if think:
        vis = re.sub(r"<think>.*?(?:</think>\s*|$)", "", full, flags=re.S)
        if len(vis) > len(text) and vis.startswith(text): emit({"type": "delta", "text": vis[len(text):]}); text = vis
    return text, [calls[k] for k in sorted(calls)]

def chat(client_msgs, emit, fast=False, tools=True, opts=None, think=False):
    msgs = build_messages(client_msgs, fast, opts)
    temp = 0.3 if (tools and wants_code(client_msgs)) else 0.7
    retried = False
    for it in range(MAX_ITER):
        text, calls = llm_stream(msgs, emit, fast, tools, think, temp)
        if not calls and tools and not retried and BADTAG.search(text or ""):
            retried = True
            emit({"type": "clear"})
            msgs.append({"role": "user", "content": "SYSTEM-HINWEIS: Du hast gar kein Werkzeug aufgerufen, es wurde KEIN Bild erzeugt. Rufe jetzt wirklich generate_image oder edit_image auf (detaillierter englischer Prompt). Schreibe keinen Text wie [Erzeugte Bilder: ...]."})
            continue
        if not calls: return
        msgs.append({"role": "assistant", "content": text or None, "tool_calls": [
            {"id": c["id"], "type": "function", "function": {"name": c["name"], "arguments": c["args"] or "{}"}} for c in calls]})
        for c in calls:
            try: args = json.loads(c["args"] or "{}")
            except Exception: args = {}
            emit({"type": "tool", "name": c["name"], "prompt": args.get("prompt", args.get("filename", ""))})
            try:
                if c["name"] == "create_file":
                    fid, fname = tool_file(args)
                    emit({"type": "file", "id": fid, "name": fname})
                    msgs.append({"role": "tool", "tool_call_id": c["id"], "content": f"Datei {fname} erstellt, der Nutzer kann sie herunterladen."})
                    continue
                if c["name"] == "generate_image": ids = tool_generate(args, opts)
                elif c["name"] == "edit_image": ids = tool_edit(args, opts)
                else: raise ValueError("unbekanntes Werkzeug")
                for i in ids: emit({"type": "image", "id": i})
                res = "Bild(er) erzeugt, ID(s) " + ", ".join(ids) + ". Sie werden dem Nutzer bereits angezeigt."
            except Exception as e:
                emit({"type": "error", "text": f"{c['name']}: {e}"})
                res = f"FEHLER: {e}"
            msgs.append({"role": "tool", "tool_call_id": c["id"], "content": res})
    emit({"type": "error", "text": "Zu viele Werkzeug-Schritte, abgebrochen."})

# ---------------- HTTP ----------------
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _send(self, code, data, ctype="application/json"):
        if isinstance(data, (dict, list)): data = json.dumps(data).encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            return self._send(200, open(os.path.join(HERE, "index.html"), "rb").read(), "text/html; charset=utf-8")
        if u.path.startswith("/img/"):
            try:
                data = open(img_path(u.path[5:]), "rb").read()
                return self._send(200, data, "image/png" if data[:4] == b"\x89PNG" else "image/jpeg")
            except Exception: return self._send(404, {"error": "nicht gefunden"})
        if u.path == "/api/gallery": touch(); return self._send(200, gallery_list())
        if u.path == "/api/chats/list": return self._send(200, chats_list())
        if u.path == "/api/chats/get":
            try: return self._send(200, open(chat_file(parse_qs(u.query).get("id", [""])[0]), "rb").read())
            except Exception: return self._send(404, {"error": "nicht gefunden"})
        if u.path.startswith("/file/"):
            try:
                _, _, fid, name = u.path.split("/", 3)
                fp = os.path.join(FILES, fid + "__" + os.path.basename(name))
                if not re.fullmatch(r"[0-9a-f]{6}", fid): raise ValueError
                data = open(fp, "rb").read()
            except Exception: return self._send(404, {"error": "nicht gefunden"})
            self.send_response(200); self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="%s"' % os.path.basename(name))
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        if u.path == "/api/memory":
            touch(); return self._send(200, {"memory": load_memory()})
        if u.path == "/api/prefs":
            try: return self._send(200, open(os.path.join(STORE, "prefs.json"), "rb").read())
            except Exception: return self._send(200, {})
        if u.path == "/api/status":
            st = {}
            for n, url in (("llm", LLM + "/health"), ("fast", LLM_FAST + "/health"), ("comfy", COMFY + "/system_stats")):
                try: http("GET", url, timeout=3); st[n] = True
                except Exception: st[n] = False
            st["idle_left"] = idle_left()
            return self._send(200, st)
        self._send(404, {"error": "nicht gefunden"})
    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        if u.path == "/api/prefs":
            try:
                p = json.loads(body); t = p.get("theme")
                if t in ("dark", "light"): open(os.path.join(STORE, "prefs.json"), "w").write(json.dumps({"theme": t}))
                if "memory" in p: save_memory(str(p.get("memory") or ""))
            except Exception: return self._send(400, {"error": "ungueltig"})
            return self._send(200, {"ok": True})
        if u.path == "/api/upload":
            touch(); i = new_id("img"); save_img(i, body); return self._send(200, {"id": i})
        if u.path == "/api/doc":
            touch()
            try:
                from urllib.parse import unquote
                name = os.path.basename(unquote(parse_qs(u.query).get("name", ["datei"])[0]))[:120] or "datei"
                r = save_doc(name, body); touch(); return self._send(200, r)
            except Exception as e: return self._send(500, {"error": f"{type(e).__name__}: {e}"})
        if u.path == "/api/pdf":
            touch()
            try:
                d = json.loads(body); txt = re.sub(r"\[(?:Erzeugte|Erstellte)[^\]]*\]", "", str(d.get("text", ""))).strip()
                if not txt: raise ValueError("kein Text")
                fid, nm = tool_file({"filename": "Dokument.pdf", "content": txt, "title": str(d.get("title", ""))})
                return self._send(200, {"id": fid, "name": nm})
            except Exception as e: return self._send(500, {"error": f"{type(e).__name__}: {e}"})
        if u.path == "/api/chats/save":
            try:
                d = json.loads(body); p = chat_file(d["id"])
                open(p, "w", encoding="utf-8").write(json.dumps({"title": str(d.get("title", ""))[:80], "hist": d.get("hist", [])}))
                return self._send(200, {"ok": True})
            except Exception as e: return self._send(400, {"error": str(e)})
        if u.path == "/api/chats/del":
            try: os.remove(chat_file(json.loads(body)["id"])); return self._send(200, {"ok": True})
            except Exception as e: return self._send(400, {"error": str(e)})
        if u.path == "/api/gallery_del":
            try:
                i = json.loads(body)["id"]
                if not i.startswith("gen_"): raise ValueError("nur erzeugte Bilder")
                for p in (img_path(i), img_path(i) + ".txt"):
                    try: os.remove(p)
                    except Exception: pass
                return self._send(200, {"ok": True})
            except Exception as e: return self._send(400, {"error": str(e)})
        if u.path == "/api/chat":
            try:
                req_j = json.loads(body); msgs = req_j.get("messages") or []; fast = bool(req_j.get("fast")); notools = bool(req_j.get("summary"))
                opts = req_j.get("imgopts") if isinstance(req_j.get("imgopts"), dict) else {}; regen = req_j.get("regen"); think = bool(req_j.get("think")) and not notools
            except Exception: return self._send(400, {"error": "ungueltige Anfrage"})
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache"); self.send_header("Connection", "close"); self.end_headers()
            def emit(ev):
                self.wfile.write(b"data: " + json.dumps(ev).encode() + b"\n\n"); self.wfile.flush()
            with ALOCK: ACTIVE[0] += 1
            touch()
            try:
                if regen:
                    p = load_prompt(str(regen))
                    if p.startswith("(Prompt nicht"): raise ValueError("Prompt dieses Bildes ist nicht gespeichert")
                    emit({"type": "tool", "name": "generate_image", "prompt": p[:200]})
                    for i in tool_generate({"prompt": p}, opts): emit({"type": "image", "id": i})
                else: chat(msgs, emit, fast, not notools, opts, think)
            except BrokenPipeError: return
            except Exception as e:
                try: emit({"type": "error", "text": f"{type(e).__name__}: {e}"})
                except Exception: return
            finally:
                with ALOCK: ACTIVE[0] -= 1
                touch()
            try: emit({"type": "done"})
            except Exception: pass
            self.close_connection = True
            return
        self._send(404, {"error": "nicht gefunden"})

if __name__ == "__main__":
    threading.Thread(target=idle_watch, daemon=True).start()
    print(f"Chat-App auf Port {PORT} (LLM {LLM}, ComfyUI {COMFY})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
