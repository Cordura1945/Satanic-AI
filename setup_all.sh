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
        frac = min((size("/workspace/ComfyUI/models") + size("/workspace/models")) / 37e9, 1.0)
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
  nohup bash -c "sleep \$((AUTO_STOP_H*3600)); runpodctl remove pod \$RUNPOD_POD_ID" > /dev/null 2>&1 &
fi

echo "=== 1/5 ComfyUI installieren ==="
cd /workspace || exit 1
[ -d ComfyUI ] || git clone https://github.com/comfyanonymous/ComfyUI
cd ComfyUI || exit 1
pip install -q -r requirements.txt
pip install -q -U huggingface_hub
cd custom_nodes
[ -d ComfyUI-GGUF ] || git clone https://github.com/city96/ComfyUI-GGUF
pip install -q -r ComfyUI-GGUF/requirements.txt
cd ..


echo "--- Workflows einrichten ---"
WF=/workspace/ComfyUI/user/default/workflows
mkdir -p "$WF"
base64 -d <<'EOF_T2I' | gunzip > "$WF/Text2Image.json"
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
EOF_T2I
base64 -d <<'EOF_I2I' | gunzip > "$WF/Image2Image.json"
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
EOF_I2I
ls -l "$WF"
echo "--- Chat-App einrichten ---"
mkdir -p /workspace/chatapp
base64 -d <<'EOF_SRV' | gunzip > /workspace/chatapp/server.py
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
uKS3TfXH1YZwcpLGNBv/BwSw14c7TgAA
EOF_SRV
base64 -d <<'EOF_HTML' | gunzip > /workspace/chatapp/index.html
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
/wHTf2fKCTgAAA==
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
for repo, f, dest in jobs:
    try:
        d(repo, f, local_dir=dest, token=tok); print("OK    ", f)
    except Exception as e:
        print("FEHLER", f, type(e).__name__, str(e)[:160])
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

python3 - <<'PY2'
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
    [ -d llama.cpp ] || git clone https://github.com/ggml-org/llama.cpp
    cd llama.cpp
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
cd /workspace/ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8818 > comfy.log 2>&1 &

echo "=== 5/5 LLM-Server starten (Port 8080) ==="
M=/workspace/models/llm/Qwen3.8-27B-Uncensored-Q4_K_M.gguf
if [ "$LLM_OK" = "1" ] && [ -f "$M" ]; then
  cd /workspace
  MMP=""; [ -f /workspace/models/llm/mmproj.gguf ] && MMP="--mmproj /workspace/models/llm/mmproj.gguf"
  nohup ./llama.cpp/build/bin/llama-server -m "$M" $MMP -ngl 99 -c 32768 -fa on --cache-type-k q8_0 --cache-type-v q8_0 --jinja --host 0.0.0.0 --port 8080 > /workspace/llm.log 2>&1 &
  F9=/workspace/models/llm/fast9b.gguf
  if [ -f "$F9" ]; then nohup ./llama.cpp/build/bin/llama-server -m "$F9" -ngl 99 -c 16384 -fa on --jinja --host 0.0.0.0 --port 8081 > /workspace/llm_fast.log 2>&1 & fi
  echo "LLM startet (Laden dauert 1-2 Minuten, Log: tail -f /workspace/llm.log)"
else
  echo "LLM nicht gestartet (Build oder Modell fehlt)."
fi

echo "=== Chat-App starten (Port 8000) ==="
pkill -f status.py; sleep 1
cd /workspace/chatapp && nohup python server.py > /workspace/chatapp.log 2>&1 &
echo "FERTIG. CHAT: Port 8000 (alles in einem). ComfyUI: 8818. Nur-LLM-Chat: 8080. Warte 2-3 Min, bis oben LLM ✓ und Bild ✓ steht."
