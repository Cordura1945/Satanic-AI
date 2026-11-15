# Projekt-Hinweise fuer die KI (Satanic-AI)

## Aufbau
- chat/server.py: Chat-Server auf dem Pod (Python, nur Standardbibliothek). System-Prompt (SYSTEM), Werkzeuge (TOOLS, DEV_TOOLS), Chat-Schleife (chat), Web-Schnittstellen (/api/...).
- chat/index.html: Chat-Oberflaeche, eine Datei mit HTML, CSS und JavaScript.
- chat/Text2Image.json, chat/Image2Image.json: ComfyUI-Workflows fuer Bilder.
- setup_template.sh: Setup-Skript fuer den Pod (Modelle laden, Dienste starten). Zeilen mit @@EMBED:...@@ nicht anfassen.
- tools/build_setup.py: baut aus setup_template.sh und chat/ die Datei setup_all.sh. Laeuft im Build automatisch.
- tools/smoke_test.py: Probelauf des Chat-Servers mit nachgebautem Sprachmodell. Laeuft bei "build_setup.py --check" mit.
- KIStart.swift: Starter-App fuer iPhone (SwiftUI). project.yml gehoert dazu.
- app.html: Starter-App fuer Android und Windows (eine Datei). main.js, package.json, capacitor.config.json sind die Huelle.
- .github/workflows/build.yml: baut ipa, apk und exe und legt sie im Release latest-<branch> ab.
- web/: alter Stand, wird nicht gebaut. Nicht aendern.

## Regeln
- Aenderungen am Chat (Verhalten, Werkzeuge, Oberflaeche): nur chat/server.py und chat/index.html.
- setup_all.sh nie anlegen, bearbeiten oder pushen. Die Datei wird erzeugt.
- Nichts aus Base64 entpacken: alle Quelltexte liegen als normale Dateien vor.
- Nach jeder Aenderung pruefen: run mit "python3 tools/build_setup.py --check" im Projektordner.
- Das Setup-Skript hat eine Groessengrenze (die Pruefung nennt sie). Wird sie ueberschritten, startet kein Pod mehr. chat/server.py und chat/index.html deshalb schlank halten: nichts Unnoetiges einbauen, keine grossen eingebetteten Daten.
- Fertig heisst: git_push, danach build_status. Die ipa, apk und exe entstehen dabei automatisch, nichts von Hand uebertragen.
- Will der Nutzer die fertige ipa, apk oder exe: get_build aufrufen (alle drei in einem ZIP: zip=true). Nie selbst mit curl oder gh herunterladen.
- Vorhandene Dateien (ZIP, Bilder, Binaerdateien) mit send_file uebergeben. create_file kann nur Text und PDF.
- Build-Dateien nicht entpacken oder pruefen. Icons in einer ipa liegen in einem Apple-eigenen PNG-Format, das sich hier nicht lesen laesst. Ein erfolgreicher Build ist der Nachweis.
- App-Icon: icon.png im Hauptordner, 1024x1024 PNG. Nur diese Datei ersetzen, der Build verteilt sie auf ipa, apk und exe.
- Vor git_push mit "git status --short" pruefen, dass nur gewollte Dateien geaendert sind, oder bei git_push files angeben.
- Zugangs-Token nie in Befehle, Dateien oder Notizen schreiben.
- Bild oder Dokument aus dem Chat: mit use_upload ins Projekt legen, nicht auf dem Server danach suchen.
- git_push prueft vor dem Push die Syntax und fuehrt hier zusaetzlich "tools/build_setup.py --check" samt Probelauf aus. Schlaegt das fehl, wird nichts gepusht.
- Aenderungen an chat/server.py sind heikel: ein Fehler legt den Chat lahm. Kleine Schritte, nach jedem Schritt pruefen.
- Build ohne Code-Fehler gescheitert (Aussetzer bei GitHub): build_rerun statt eines leeren Commits.
- Loeschen, Verschieben, Umbenennen: mit run (rm, mv). Letzten Commit zuruecknehmen: run "git revert --no-edit HEAD", danach git_push.
- Grosse Dateien stueckweise lesen: erst search nach dem Funktionsnamen, dann read_file ab der gefundenen Zeile.
- chat/server.py darf nur die Python-Standardbibliothek nutzen (auf dem Pod wird nichts nachinstalliert).
