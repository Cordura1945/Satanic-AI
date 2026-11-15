# Projekt-Hinweise fuer die KI (Satanic-AI)

## Aufbau
- chat/server.py: Chat-Server auf dem Pod (Python, nur Standardbibliothek). System-Prompt (SYSTEM), Werkzeuge (TOOLS, DEV_TOOLS), Chat-Schleife (chat), Web-Schnittstellen (/api/...).
- chat/index.html: Chat-Oberflaeche, eine Datei mit HTML, CSS und JavaScript.
- chat/Text2Image.json, chat/Image2Image.json: ComfyUI-Workflows fuer Bilder.
- setup_template.sh: Setup-Skript fuer den Pod (Modelle laden, Dienste starten). Zeilen mit @@EMBED:...@@ nicht anfassen.
- tools/build_setup.py: baut aus setup_template.sh und chat/ die Datei setup_all.sh. Laeuft im Build automatisch.
- KIStart.swift: Starter-App fuer iPhone (SwiftUI). project.yml gehoert dazu.
- app.html: Starter-App fuer Android und Windows (eine Datei). main.js, package.json, capacitor.config.json sind die Huelle.
- .github/workflows/build.yml: baut ipa, apk und exe und legt sie im Release latest-<branch> ab.
- web/: alter Stand, wird nicht gebaut. Nicht aendern.

## Regeln
- Aenderungen am Chat (Verhalten, Werkzeuge, Oberflaeche): nur chat/server.py und chat/index.html.
- setup_all.sh nie anlegen, bearbeiten oder pushen. Die Datei wird erzeugt.
- Nichts aus Base64 entpacken: alle Quelltexte liegen als normale Dateien vor.
- Nach jeder Aenderung pruefen: run mit "python3 tools/build_setup.py --check" im Projektordner.
- Fertig heisst: git_push, danach build_status. Die ipa, apk und exe entstehen dabei automatisch, nichts von Hand uebertragen.
- Grosse Dateien stueckweise lesen: erst search nach dem Funktionsnamen, dann read_file ab der gefundenen Zeile.
- chat/server.py darf nur die Python-Standardbibliothek nutzen (auf dem Pod wird nichts nachinstalliert).
