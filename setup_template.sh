#!/bin/bash
# Neustart-Skript: ComfyUI + FLUX.2 Klein 9B (uncensored) + LoRAs + Upscaler + Text-LLM (llama.cpp)
# Aufruf in Jupyter (Terminal-Zelle):  !HF_TOKEN=hf_DEIN_NEUER_TOKEN bash setup_all.sh
# Ports (beim Pod als HTTP-Ports eintragen): 8000 = Chat-App (Hauptseite), 8818 = ComfyUI, 8080 = LLM-Rohchat

if [ -z "$HF_TOKEN" ]; then
  echo "FEHLER: HF_TOKEN fehlt. Aufruf: HF_TOKEN=hf_xxx bash setup_all.sh"
  exit 1
fi
export HF_TOKEN

echo "--- Statusseite (Port 8000) starten ---"
mkdir -p /workspace
cat > /workspace/status.py <<'PYS'
import json, os, re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LABELS = ["Starte", "ComfyUI installieren", "Modelle laden", "llama.cpp bauen", "ComfyUI starten", "LLM starten", "Chat starten"]
def size(p):
    t = 0
    for r, _, fs in os.walk(p):
        for f in fs:
            try: t += os.path.getsize(os.path.join(r, f))
            except Exception: pass
    return t
def calc(text):
    st = 0
    for m in re.finditer(r"=== (\d)/5", text): st = int(m.group(1))
    if "Chat-App starten" in text: st = 6
    frac = 0.0
    if st == 2:
        frac = min((size("/workspace/ComfyUI/models") + size("/workspace/models")) / (48.6e9 if os.environ.get("DEV_SERVER") == "1" else 37e9), 1.0)
    if st == 3:
        try:
            ms = re.findall(r"\[\s*(\d+)%\]", open("/tmp/build.log", errors="ignore").read())
            if ms: frac = int(ms[-1]) / 100.0
        except Exception: pass
    pct = {0: 5, 1: 8, 2: 12 + 50 * frac, 3: 62 + 23 * frac, 4: 87, 5: 92, 6: 97}[st]
    return int(pct), LABELS[st]
class H(BaseHTTPRequestHandler):
    def log_message(s, *a): pass
    def do_GET(s):
        try: text = open("/workspace/setup.log", errors="ignore").read().replace("\r", "\n")
        except Exception: text = ""
        lines = [l[:160] for l in text.split("\n") if l.strip()][-6:]
        try: pct, label = calc(text)
        except Exception: pct, label = 8, "Setup"
        b = json.dumps({"phase": "setup", "log": lines, "pct": pct, "label": label}).encode()
        s.send_response(200); s.send_header("Content-Type", "application/json")
        s.send_header("Access-Control-Allow-Origin", "*"); s.send_header("Content-Length", str(len(b)))
        s.end_headers(); s.wfile.write(b)
if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
PYS
nohup python3 /workspace/status.py > /dev/null 2>&1 &
if [ -n "$AUTO_STOP_H" ] && [ "$AUTO_STOP_H" != "0" ]; then
  nohup bash -c "sleep \$((AUTO_STOP_H*3600)); if [ -n \"\$RUNPOD_POD_ID\" ]; then runpodctl remove pod \$RUNPOD_POD_ID; elif [ -n \"\$CONTAINER_ID\" ]; then curl -s -X DELETE -H \"Authorization: Bearer \$CONTAINER_API_KEY\" https://console.vast.ai/api/v0/instances/\$CONTAINER_ID/; fi" > /dev/null 2>&1 &
fi

echo "=== 1/5 ComfyUI installieren ==="
cd /workspace || exit 1
# Dev-Server (DEV_SERVER=1): ohne Bildteil, mit grossem Programmier-Modell
DEV=0; [ "$DEV_SERVER" = "1" ] && DEV=1
if [ "$DEV" = "0" ]; then
[ -d ComfyUI ] || git clone https://github.com/comfyanonymous/ComfyUI
cd ComfyUI || exit 1
pip install -q -r requirements.txt
pip install -q -U huggingface_hub
pip install -q pypdf reportlab || true
(apt-get update -qq; apt-get install -y -qq fonts-dejavu-core fonts-dejavu-extra nodejs) >/dev/null 2>&1 || true
cd custom_nodes
[ -d ComfyUI-GGUF ] || git clone https://github.com/city96/ComfyUI-GGUF
pip install -q -r ComfyUI-GGUF/requirements.txt
cd ..


echo "--- Workflows einrichten ---"
WF=/workspace/ComfyUI/user/default/workflows
mkdir -p "$WF"
cat > "$WF/Text2Image.json" <<'EOF_T2I'
@@EMBED:chat/Text2Image.json@@
EOF_T2I
cat > "$WF/Image2Image.json" <<'EOF_I2I'
@@EMBED:chat/Image2Image.json@@
EOF_I2I
ls -l "$WF"
else
pip install -q -U huggingface_hub
pip install -q pypdf reportlab || true
(apt-get update -qq; apt-get install -y -qq fonts-dejavu-core fonts-dejavu-extra nodejs) >/dev/null 2>&1 || true
fi
echo "--- Chat-App einrichten ---"
mkdir -p /workspace/chatapp
# Dev-Modus: Befehle der KI laufen als eigener Nutzer ohne Root-Rechte, nur im Projektordner
id agent >/dev/null 2>&1 || useradd -m -s /bin/bash agent >/dev/null 2>&1 || true
mkdir -p /workspace/projects
chmod a+rx /workspace /workspace/chatapp 2>/dev/null || true
chown -R agent:agent /workspace/projects 2>/dev/null || chmod -R a+rwX /workspace/projects
cat > /workspace/chatapp/server.py <<'EOF_SRV'
@@EMBED:chat/server.py@@
EOF_SRV
cat > /workspace/chatapp/index.html <<'EOF_HTML'
@@EMBED:chat/index.html@@
EOF_HTML

echo "=== 2/5 Modelle laden (ca. 37 GB) ==="
mkdir -p /workspace/models/llm models/upscale_models
python - <<'PY'
import os, shutil
from huggingface_hub import hf_hub_download as d
tok = os.environ["HF_TOKEN"]
B = "/workspace/ComfyUI/models/"
jobs = [
 ("unsloth/FLUX.2-klein-9B-GGUF", "flux-2-klein-9b-Q8_0.gguf", B+"diffusion_models"),
 ("ponpoke/flux2-klein-9b-uncensored-text-encoder", "flux2-klein-9b-uncensored-q8_0.gguf", B+"text_encoders"),
 ("diroverflo/FLux_Klein_9B_NSFW", "Flux Klein - NSFW v2.safetensors", B+"loras"),
 ("B4100/fnd", "NaturalBeautyFLUX2Klein9BNudity_v2.safetensors", B+"loras"),
 ("Kim2091/UltraSharp", "4x-UltraSharp.safetensors", B+"upscale_models"),
 ("orcarouter/Qwen3.8-27B-Uncensored-GGUF", "Qwen3.8-27B-Uncensored-Q4_K_M.gguf", "/workspace/models/llm"),
]
DEV = os.environ.get("DEV_SERVER") == "1"
if DEV: jobs = [("bartowski/huihui-ai_Qwen3-Coder-Next-abliterated-GGUF", "huihui-ai_Qwen3-Coder-Next-abliterated-Q4_K_M.gguf", "/workspace/models/llm")]
for repo, f, dest in jobs:
    try:
        d(repo, f, local_dir=dest, token=tok); print("OK    ", f)
    except Exception as e:
        print("FEHLER", f, type(e).__name__, str(e)[:160])
if DEV: raise SystemExit
if os.path.exists(B+"vae/flux2-vae.safetensors"):
    print("OK     flux2-vae vorhanden")
else:
  try:
    p = d("Comfy-Org/flux2-dev", "split_files/vae/flux2-vae.safetensors", local_dir="/tmp/vae", token=tok)
    os.makedirs(B+"vae", exist_ok=True)
    shutil.move(p, B+"vae/flux2-vae.safetensors"); print("OK     flux2-vae.safetensors")
  except Exception as e:
    print("FEHLER flux2-vae", type(e).__name__, str(e)[:160])
try:
    from huggingface_hub import list_repo_files
    fs = [f for f in list_repo_files("orcarouter/Qwen3.8-27B-Uncensored-GGUF", token=tok) if "mmproj" in f.lower()]
    fs.sort(key=lambda f: ("f16" not in f.lower(), f))
    if os.path.exists("/workspace/models/llm/mmproj.gguf"):
        print("OK     mmproj vorhanden")
    elif fs:
        d("orcarouter/Qwen3.8-27B-Uncensored-GGUF", fs[0], local_dir="/workspace/models/llm", token=tok)
        os.replace("/workspace/models/llm/"+fs[0], "/workspace/models/llm/mmproj.gguf"); print("OK     mmproj", fs[0])
    else:
        print("HINWEIS: keine mmproj-Datei im Repo (Bilder anschauen geht dann nicht)")
except Exception as e:
    print("FEHLER mmproj", type(e).__name__, str(e)[:160])
PY

[ "$DEV" = "1" ] || python3 - <<'PY2'
import os
from huggingface_hub import hf_hub_download as d, list_repo_files
tok=os.environ.get("HF_TOKEN") or None
os.makedirs("/workspace/models/llm", exist_ok=True)
T="/workspace/models/llm/fast9b.gguf"
if os.path.exists(T): print("OK     fast9b vorhanden")
else:
  for repo in ("mradermacher/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF","xtools-at/DeepSeek-V4-Pro-Qwen3.5-9B-UNCENSORED-heretic-GGUF"):
    try:
      fs=[f for f in list_repo_files(repo, token=tok) if f.lower().endswith(".gguf") and "q4_k_m" in f.lower() and "mmproj" not in f.lower()]
      if not fs: continue
      p=d(repo, fs[0], local_dir="/workspace/models/llm", token=tok)
      os.replace(p, T); print("OK     fast9b", repo, fs[0]); break
    except Exception as e: print("HINWEIS fast9b", repo, type(e).__name__, str(e)[:120])
  else: print("HINWEIS: 9B-Schnellmodell nicht gefunden, wird uebersprungen")
PY2

echo "=== 3/5 llama.cpp bauen (5-10 Minuten) ==="
cd /workspace
export PATH=/usr/local/cuda/bin:$PATH
if ! command -v nvcc >/dev/null 2>&1; then
  echo "WARNUNG: nvcc (CUDA-Compiler) nicht gefunden. LLM-Teil wird uebersprungen. ComfyUI laeuft trotzdem."
  LLM_OK=0
else
  cd /workspace
  if [ ! -x llama.cpp/build/bin/llama-server ]; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq cmake build-essential git libssl-dev >/dev/null 2>&1
    # Schlanker Download mit Wiederholung: ein Verbindungsaussetzer bei GitHub soll den Start nicht kippen
    for i in 1 2 3 4; do
      [ -f llama.cpp/CMakeLists.txt ] && break
      rm -rf llama.cpp
      git -c http.version=HTTP/1.1 clone --depth 1 https://github.com/ggml-org/llama.cpp && break
      echo "HINWEIS: llama.cpp laden, Versuch $i fehlgeschlagen"; sleep $((i * 10))
    done
    cd llama.cpp || { echo "FEHLER: llama.cpp konnte nicht geladen werden"; cd /workspace; mkdir -p llama.cpp; cd llama.cpp; }
    cmake -B build -DGGML_CUDA=ON >/tmp/cmake.log 2>&1 && \
    cmake --build build --config Release -j"$(nproc)" --target llama-server >/tmp/build.log 2>&1
  else
    echo "llama-server schon vorhanden, Build uebersprungen."
    cd llama.cpp
  fi
  if [ -x build/bin/llama-server ]; then LLM_OK=1; echo "llama-server gebaut."; else LLM_OK=0; echo "WARNUNG: Build fehlgeschlagen, siehe /tmp/build.log (tail -30 /tmp/build.log)"; fi
  cd /workspace
fi

echo "=== 4/5 ComfyUI starten (Port 8818) ==="
if [ "$DEV" = "0" ]; then cd /workspace/ComfyUI; nohup python main.py --listen 0.0.0.0 --port 8818 > comfy.log 2>&1 & fi

echo "=== 5/5 LLM-Server starten (Port 8080) ==="
M=/workspace/models/llm/Qwen3.8-27B-Uncensored-Q4_K_M.gguf
CTX=32768; if [ "$DEV" = "1" ]; then M=/workspace/models/llm/huihui-ai_Qwen3-Coder-Next-abliterated-Q4_K_M.gguf; CTX=65536; fi
if [ "$LLM_OK" = "1" ] && [ -f "$M" ]; then
  cd /workspace
  MMP=""; [ "$DEV" = "0" ] && [ -f /workspace/models/llm/mmproj.gguf ] && MMP="--mmproj /workspace/models/llm/mmproj.gguf"
  nohup ./llama.cpp/build/bin/llama-server -m "$M" $MMP -ngl 99 -c $CTX -fa on --cache-type-k q8_0 --cache-type-v q8_0 --jinja --host 0.0.0.0 --port 8080 > /workspace/llm.log 2>&1 &
  F9=/workspace/models/llm/fast9b.gguf
  if [ "$DEV" = "0" ] && [ -f "$F9" ]; then nohup ./llama.cpp/build/bin/llama-server -m "$F9" -ngl 99 -c 16384 -fa on --jinja --host 0.0.0.0 --port 8081 > /workspace/llm_fast.log 2>&1 & fi
  echo "LLM startet (Laden dauert 1-2 Minuten, Log: tail -f /workspace/llm.log)"
else
  echo "LLM nicht gestartet (Build oder Modell fehlt)."
fi

echo "=== Chat-App starten (Port 8000) ==="
pkill -f status.py; sleep 1
cd /workspace/chatapp && nohup python server.py > /workspace/chatapp.log 2>&1 &
echo "FERTIG. CHAT: Port 8000 (alles in einem). ComfyUI: 8818. Nur-LLM-Chat: 8080. Warte 2-3 Min, bis oben LLM ✓ und Bild ✓ steht."
