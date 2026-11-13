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
H4sIAFx99moC/+1caXsaSZL+zq/IrXlmVfRACR1223i1+8g2sr0tWxpL7p5pzDIFlUCZogrXoXP5
7/tGZGYdUMhWd8982p6xEHlERsadkZH607/tZkm8O/LDXRleieVtOovCg4ZlWe/90G+/mrlpV/z1
WobCDgJ34bYTGV/JuCn+Ik5OP/3N2Rc/BdJH76toMbn99K7piA9ZLC5SN/Tc2Bv5o8CP0pmcOwDZ
8BfLKE7FlyQKWyJKWiKWLZHc4pfUX+DXLPM9NGJutEDbLJau54dTdMRB4I+cWH7NZJLm32UcR3Fj
EkcLMUvTpaOQE3qZSzP/7eXl+QV3tcRLN5H0/aMC9RZrBVLD0FCXbpxIAwRt/L0l+GP4NWk0Tk/f
iyPg74BkfhyFzlSmtoXW4aePp1ZLWIRMd3d3b/9Hp4P/7XWfdZ51rCZNHJ4cX1xumU1dD4HYA4hX
Z+9P/l4zn9u3T3629wyTz88+0tp+mNrr84/Pz4fUTdOfdTrAttm4uDz72KtZi9tp4O51FM+TpTuW
u2NIirtc7iZpFEss9bZnpi7ddOZ4fhy6C2mb7+4ooU97OJz4gRwOsVrv9bvL4enZx+OaFfM+WhW4
iaMjYe1ZjffHfxu+u+x9xJTDBiYt3LnEUonNKLaEvPGTdBjNjy7jTDYbjU8fekQAaxJkN+399pxk
t/181P7rs2HHmU6zidV4dfru3AwpjcjCsQwT7M1rfy0G/3zcK8ZeudJJ3IlMeWBiNfRmrBN0az1p
iw8XJ7+Iq/3qyE/nFzTw8Kb9KUhj92LmxsvqiMbF3y8ueyR3dkNYrzMxk36SpOICZA/9schCT4yw
WYFVJL7dYaIv41SKn9450EcZBFJ4/ngmRtIXLyW0cyLcIMkBXEWxI36RYSi8TJxDHZYp9PKlnMhZ
AOl/FXlS4F8sJoDqT2ERLuVNKgIfI2LSSQ9N1P8hS+/wMY+WWB9tSRQE0HKJVvFF0iigeCeDkMa7
V1EIeWSs6Sfg4pMWGwXReC4Wfiq8mDB2x/PUH88TYf/jH/9ownzMsM9ePA9cGWch4eMvxEuaBFRc
mkeWYBYyCAK/EJf+clngNXfD0BEv/cBr59v1fEnb9zBYbyOENbvLFuInM23qj0Blm5dPZDBSJGc4
GIhF72QGbIChHMlw4gagcRIJN0um1GBoXBBKbV2hIK59IpYiqhQXZyeksWpETnc9FNst6GQTV5lV
IVH4tUxdHwsTZokfhlfggUzATT/BNoImi8skdqfYrhu6kIpZJMezhMRNzLP4riWu3US4oOvSJTG7
lrGneemIE54YglaKOtAtojqTBGI0W99UBdOpVLtLiVozl0lyMYap9kdSzFl637vx3Iuuw/YnUCxO
0OlPUhpnKdE3cg75DaZyQXNg2Wd+MAGU8Yy+lBQgFsdJ4tPWwDZGHc6HZBdSDQSnsbtYMGtb4jh0
g1uy9R8lgcG/9ltARYNL9FNkI7lJCPvEhUwHpFLEfNq05r1SRunGYArjXVmGe8MoXrjQyDcyWcYu
rUZ88kCdEJISQQ7GM3Abn1JDfyGSkhIT8Ul7Y0VoluJ8m2hgbT4OUxhomABfCdwFlqKVPIiCEj5o
E8iH3byWWQpCQ2qJxiQBjCZsqZynDroLvcb2zYZn0XgWuCQYNml2An5qA/TuNaPuL6ZDd7S3P/Ze
iJ99T0aQrmixkCEjb+wACdQC5M0ZPHOJwNcQ6V9kPGeidj+H1NkmCsnYTeXQX4CV9pJFrNnVxFdy
8aH3qXehVBLUZGY7Zj78Q1qZ2xL8beh7CcDkbEtZlF1SJ8MCYe8pE7iP/RG60Cf1O6bd+XKmmQN5
15LvZhOxw+DF3g5TVH/b39EIMVUZabNVUiqo36aVUBsy+2REENK4pPHQJlYlth/Qp4gk1DXsV8LG
hpBJwWTOdc4z8pNr6wKQCfPehzen7y5evW2BaeE8BklYJti2BKRbLW5Qpp1M5y8ZlG5dwtgsHI/Q
fk2CDlstsoXCoaf2ktNX7aGwm0RZGwwfOo6jlS8CXcgQLaF8mHFNrIrLXFOWSsFvizFCQMgKBRk2
/aAgpCXGESkJSU0gp1piiTIexvoUy3oY9Pby/Sn83sXPsBZ/u2zlVqkl/vvi7INglNxQ+4yCUTNy
R8BJ6YVyMprJSS1bpXjNyxYMVLzlLng32GC4gmP4DwwQtrElLfE6mmcL2gYrkwJijL2AUpfsKqHy
09n789Pe5WXvg3gXztwAIoMV/NAIInkBcny5HCZmNll5ZWfIMOADMcOdYzWajcuzs1OKXPoNcW+l
t0tpdRENIVZK/SikWC3/vYsBRHwaUFVhq9UQwoLEjGN/qccayWCxD2VGvstoM5t7AbIEPskahFdq
TCFajoKGWB1rgQsJL2wwi0Zf5DglvKD6S/KnkgdgiuA2yH9lQpLGOD/QhDX8XhdKUEYmLmuStWop
wNe+l84qcBGBS7C1BvDLmMS4BWspgwlZ60RQiLT3tJUfqsReZ/8wB444cDpLvxP62whG6hHAs2Uy
hpuqQB9FUSDdsAb64Q17hGTuBsrT2SQ5LPJgnMdhAvvLqbxWliJtWiu1lkVnO3gbD4D6hhWDFfc+
QrQK614rVi8LO5Gb8k0z74bUsCloxyHMTfIvlLKeWbtYWgdmC6UPU2nM/7UfeznbcodWWcaNY/eW
VsH+F0kdBqtNFHIysWDDID/IsFZ57cdzr2Stt1gFjoE2LDYF6G8rdneSAWn6RdnZ38Mw4za+0zAQ
QjSc3W0v9Jhnd85LR+B47CxvcyZpJ/R9YH8CeQOZkrHhFXxlwcnwExnqmZJj3ipWU0wZNBp/Eu21
/3QUOQooQFnvbHhyAkt8Dc4ibpIT/wbeEyFBFodCfUdKyBpa+ElZHId+HNpNZyZv+t2nA55O0SCf
+v1ml2ngA2SUAowzyYJg4abjmR1bNsb9Lx2hhv1O+7nbngzun66wB59WdH3kZn52g0z2KPljW6Bv
JgM6GRkRRfaBgGvkTMbhS+SHJi3gE64Okl4YSogl7hU5o6nt09kxdbEQ5CC0SwiDhNcjq+lcx9Ae
mwfV0lDnwerpR3kZBNzIsXmcw1KrHX2IQhjlGZJVkEz9jRJiUZYePe10NLHAWnjaaibM0WksuwBG
P1pCLXJk1jKw9aeIYnG/UmS69tPZOlR85f3je4GJ/kS0gWNHzvvYoSSbDWLQBse0+2G2DCK0GS4T
RpTT2aRoTBTV82kk682RZs+X5dR6IUa05zWB4rGjyLulbMjEarfvR6vP8efwlZLx9muccqPEJ93p
igmC3zah8ILBH31WFuozYBv9QNs9fa4+W2Uwl1DKrjoc7H5Zyin10T/gLMMxzKJNaVDe3V/EZ0ZK
/wekaOBjEYsQzrN8KTzoXwqnmYNqt9eWV3IBKlBG1SGiJzbLmHV+dkGpPJUtBDV3FU92tWtk6rVg
eMp7JTuzyKBKMJPpbgm9UZRRbHB7RNo9WjUr+hX3lfkeKAlIQne599S+gjQeUSihZSCNb7viSuce
rxQAeTOWOG/0+INJQgO8MvCFe2PvP0F4soDy7ncOn7WEfSV2dxGyNMUP9FMLHkLi5WyY7vv5oe4a
Ug8lUwEM5Z+kp3GZYhVl2ymHSOZ3HCDJMTRG+FMo09OIFOXNm08n7NPCJY7HPDRD51C7A8omasML
UPs1oE6j2FWg3oNhwVkY3K7BW1A7W+s99HQG6A0wySxBKcQW+wXEIelsaIZ3nGfFygc1K1Mac+sm
xoG/NCvQQPTmPppSmVYB+7AGNrKeCvQaWCRADVQMKWA82YIfea4ei3INfkyTA0OTlJxcVyjmFpCf
/mGQrdKef6yDevLmDSzQxp4L/u0biErFryS3PjGtoZy6eetT0zqeTNGw53SK1Z/VrP7ThUv+P76Q
gY5USigkqm+Yx8AZvpW287wGIKWk93E8lB4PXgOYyiX9dtgqzi7XrdJRY1YA3+vUQP/INzgfIvjq
NdAhtQ1JGfGVPkqQ6nSxB3bfMrKnLhmqd9p+lWHWo4gvIwoohol/R6D2SivVqaqm8KsMNxiLY+/K
RcLfq8NeKWvHcHCqpIIafzRtmiPc+Cxv9KcLN+G257mq86b0gYXhKitQwvWgXgFfyxrpVuuqNfZy
eYRacsthBfSKfwaUaTui4UohTFim7WY392pTDDm0BmQ6182lGsoGrtYssIrkNvP8YrWqQH1SC5UZ
rUH/ghCFwa/bYtU9LNnQQ7NpQ1LaYGnBYr9Piv0Ci+fPa7G4QGBYJ3IMPdHgW8UZYahCYT7LIBdq
6ZW1N8NBgBYqeyw6r+YuS0VPBCf5Vzis/3cbFchR6HFkhgPYrzKOzrJ1OzsujSjZ9qpCsSwqCaso
VH6DWVGp/Vqp++dGDfn6Bar7BapLupaHr+J247yMw+IRE9yvpkPWPA+j6Lii2nGoQDo0XPB9XojU
JOX47JJQN4u9BzhpJWPckYUAMbH278MVWVT1217+275Volbg1xPL9baqKH4LFxV7k4y3WpsL2tJl
dBmlbnDu38gg2QKyT9gz0XMLxOcsghTAb9xFPHMBj79UcNjF04FH4gYtIxkaGie7V0FPhnXoQS1q
BT6H3ida1hr7HHa8RGVFQe2DnMaHZRrHy7r1P/J1JByicsIP6wVLkPZshApdrFUwwSrh714FIvrw
KmVBpr2zHMdhLsZaLyvS7Ccszt11GdfkNc7ioFOrtm+kCk8uKOCol5wyXI0rwdurhfetkJM/q/Gm
on0p1FRkKkWZ+Zr1puc3BZo5zINamI+ONZnCWp7zgE437g1K69UHJI+KPnNY9WHIY+LPh9GuiUfz
tZ9uCT4eE5EeHNZEpAd7dSHpwX5NTHpwsDUoPXhSNiaE8I/WFjP1zbD04Kn1kKX6HaEYo6Vh/4Z4
DNnjIfsqmyMzlDNkiJuwGZN++640S54H56Fetlgm9n2R89egKVJhEnsGM+SGrVWR2KlLzWAILk9c
MoG7BN0yiRhYsViVSRG6Qy6KS6ySs1VJ049IjyOFp9OmJk95QjUjSOdRaqeEM2V1SsAGzX73sNMZ
qAWXPhnF2GT9aRuDFyLtoJFWcOiHTk5doypDlltRAYWB/yGedzoFgrM62r7pVUk786m27HaXMAUG
evOaAIQSwo5Zt5yGE5RMnPXRN6g08xFAKpIlqZtm5K5NPrQEFJnQ0hh47FhXnjFVrOpa3yI05dWz
SXsLvc1SiJISlmcICUrw+m1QvTtYw2wxTYoNQExZF3gH3GQEt2gxSrKxQwK1uQ3ULxxxV78z2Oj8
yiHEf+W50/ty1aTzNYsQ8/mL/o4ZsDNorv49yUaTiO7WtgxnLHfyUTutnZ0mppHuH92bbvqGHrXh
nebK2qS/0ut6+bny5TVR/WtBBZbLJJByacM56rTmAzz8FVeHmalJot8RiiABWZSK5jtrTJfZkOud
joo6VucUDZQqP3l32rsoVUeW7ybYdoFVL0S5npFnbNQzkt1KcR2r6hvceGpCbJ1Ix8UKaIorlf7/
HLd/ddt3uE9xhu0BSdfQauXrj1AUy+WZEHEGo6SmfH/EF21OiuNUE//1UY46cOi2CoR2oBWI/UtD
GAd94wQ0CojmFqpZvv7xUbQAFYN3s3U/zgZpzECpXzfWXf6YNajyzUCdsHWqvYSibr6GqBBe05bm
0RUW32HRtvnOx6IzCowy2HdkZemk/Sy/BDJVJGWXMqECZprcKJhjyh3KDFKWE3hWKV5co4LMmr4V
WqkBdaTQEMuUgH+LsMRmblwn6Yt1VQjTbNZ06UiG+ujmv9RjigOoS9VsO/RBGX6cdfZ/+OFJp1m6
YzIa0TUXQiWPC0T1NtGubxmpTITUYONy7oUhtl8iMidSfheBvaQiqsU9NgtiPz/Jl8QVvUpUu3p6
Hx+DErj+DR+Lb8g3UUt1+o2aPOh39webTDbij3kP8Jtv53NcdQmo0YTS0t2ytySwRgXYpCTFxdxN
c8s160hSMVOaX7OyC7upY3C+FJ/6iQyVe8GbZgWzwsVU5LWSGdM5sYelrHTX+EeIVs3lLor02zjI
oJJ7suWGfJSBOEPjxW0d5y2SXC7hvYgg91YcBerK/xZHoEX5ir4rVK33apBzkXMqJWAVbir3qACq
+CRL5Hp4YuRz0bcoXGOoPoNdVEIEHJIHzarXh0XHVD2MM2qsPhuxBMmpGmv1j1G1NqPatby4T4U8
NFVZXSq3pIYBbjTxiYkVgHQHmShKmROAWVon9Wgpcjs2FQ1zFQSKiaqYP7jJmriHAiK9zVm2wOV0
V+HhIPZGnY1dKrFijYPHL0pe6AsnXPmTCK2A4GhTpRVEoABoxIBZVhECRQHgBIW2+UtT/CfKlpDx
kaoT4VlfUWNQWoL6u7+FgVUaNRWF/wJufg77a5Wa68wkqVLTBoqp1hbgOrhZg62qenQhpAxroKt5
tcBryelyLbSrskgFTXOZieYQlmqdSJYqd4JCFAr1pbuwjR4jBkA1D0IEZPuPTlB0Yw6Fugjhvojb
kZbJJ1nkmaiJyyR1QtZdUAPCN5bkxZJCgyyWnJ39sVXZGZ8MhzSIjuTD+TV5J5YxhGUjpB1TVHDO
VT6MscqPtw9Uitj5IyTKftF1CAsUWpsqTN7jtzy7Y1VxhNNmUj3O0p4ffVJVRQAQPdxycGkvWM9H
lsfVoODUqOtPGmUdj91rUvK4KvYBFYkdUafjcVrC1gEcqew05HdKlRBgzUPSfPSTphGCNgW4bpeE
lwTKDzNZtVhYi6b0n3QH28Au2Tz3X5996A1AqRHEYV5VVaqT8KrH4WWzD0mI/DFpAHReaRJyf6lb
c27drKqoxRbIeGsx+aZBJIaRlnr9on7sBetCyRQaRIxdLg9ew414lY75OYI2RhS6sUCYKGsTiTGo
wUPwvC+FgrooUbHTsTZWqH68oawPCyLnU/IuT59LaPLWwjRKl+p0Ju1Ba5hlrWHO2NNZTgMvlTLe
1wwl1dIpGQJOImPKZIiek7xmZvtEYMLV3YmezZiZ2UXnoGzDlIL1mVr9uXLycyJ3Qu8APJs7mrpS
h7S8HKBsNXLUia0/ENrkcQpKHkkP6d2Qbd7mleSqagDKhnZt/eZ6tMpzTNFZcYOFad9v+6Uy/qq+
rix6XapfL/2nBWmsQqXyLec3ClhzJitJ0iwqs4/k8X6FPCSTi1WBcShrSrWnu2kfCFbVRGws8C2b
oEHcr6rjqppNJLIKBSnvLs9o1hyt6hMIOG+tKQrtpU4BClUhY1muCd4crg/8kBqd8lhLh9ROWNum
KjcWiukMzOyYga7qgdTLniFZLl3DNVEq5HGiaoXFvVpFSB0GtSqvKOm1Fd6xVZ+VONYWpGpNfS1Z
195gdPl4VJOu2ICE53vrsEpF9yU4xYm8BgZC1AcPmUn+DMWqmV7ln5/fChCp/RrSxHwKnVjlB1Qt
eqN2768c0Uu4er786hMpPqT31APIOyRAUsd6UKEoJpHdbyGq0saFp5xY9+P+jkqSrmBG5Mp6APmT
3tvT3kc1rPGHSiJW0Ot+A2Hr10wgjYqMvuEOHYeRDKMXK+4ID1zjiF5KsHzWHaDp5f3mwZkvesRb
u/5tfpHQSaMx9oIi2YRIDsGjwbt7zp6iBwfv0dS4KBuvcyct8YPLp7gkycfgAhCUUr1jzpOrmukx
p5s3o9dm5bRdyt+oaTbe/KX0Zhduq5knt0oBM2cWqjW7fAsBBBxCZQj6LxFmU0YR100vSj2qXtuu
Rtga0zpIZvzxGMFi0qZpkIf2cRBE1+2z2J/67Lt+sB6abBY75eIRi5NUNh1CeSNNg2AxJbFN2zXZ
0kqNvCG6Fw2RkGeql+iZqXMKp8y5j3NSFe+fcRO5Q9va5T86wDGfM0sXwXrMqsMgBqS4vN9Bkmgz
5Ut/nYCvEQtI1XJ0LfO71PeCQiUgmB7p/O8mepVjAoqsp7vrqLHjfgi/PAGnINIpYhOnohj9mx5+
c63DziEFyfryCk6O3hjjCREiGfiUsunZsi9ibu3GNmzWsEX/z5PhxGUND7qVKkYe1ETYy/VLkbrc
/MatBSfra4Pwmtcl1TclAFyT7twAVX7CMFnWvFz45/Bhi5mA0HyPlahYsmiMR29tnYDYtsI6oNJ7
BcDbcdMUjwYpqC29nbD+nFg74s/fxZV/rq15sX48KKwHRSm7KMba1de93c374LVQWFezwTix6bEt
SBDQoz/9wpfREs+vZmQ1EOXiwKK6VF5lvZ8T0ZWrSJXzHRIyON7VHbzJWpSvMfl9j8mCHBAJ0j4X
UVEmaTPu2JBCM5zPdd9jM8tnsEfLrjb4VB3xWIsf6jci3KVZrv/CzbqodEg8dAaOh8csEayVYfMh
KVAXEesZ8tL9AIzx+v0Ap71ebCPX/WbwWbMu16DU+oWvwy/VE51eTp+9eUC/yDIiCzNRlcx8J8fd
+shFwtj8LUapU2Fs6Vndcch/KeQPNEzsWuUVNX2vRaLXyiae4TNp1B5Tm7VtwVDmR/VxECXFwIot
qSxLYssRsLyq0ckNozNSCcH1Ug5MLr8PGyHF/Tm0qlYL5dLJzN48DqukzPZsSImbL+NoLsNzf6lc
1kZu5BHHFF7522cV6rJl0xlyAeBwuP3Isk3gGt9a1UNuxvpmQjOP5iusYS7j1s9wvs44rqHxKMPW
gEKbrbNKD4cL1w8Rk5gDCtmtiUV/M619jL80RH9C45wKQ+7pD2utBGXexT1+rFr5M9F7dgqrJoUi
JBO6sIPg1fz5MrihDv9FLyopJKDwL2+b6s+eDeGxJI1pNv4PZjeQ3tVNAAA=
EOF_SRV
base64 -d <<'EOF_HTML' | gunzip > /workspace/chatapp/index.html
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
ZqrJVoIvAAA=
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
