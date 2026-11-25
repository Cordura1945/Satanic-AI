# Projekt-Hinweise fuer die KI (Satanic-AI)

## Aufbau
- chat/server.py: Chat-Server auf dem Pod (Python, nur Standardbibliothek). System-Prompt (SYSTEM), Werkzeuge (TOOLS, DEV_TOOLS), Chat-Schleife (chat), Web-Schnittstellen (/api/...).
- chat/index.html: Chat-Oberflaeche, eine Datei mit HTML, CSS und JavaScript.
- chat/Text2Image.json, chat/Image2Image.json: ComfyUI-Workflows fuer Bilder.
- setup_template.sh: Setup-Skript fuer den Pod (Modelle laden, Dienste starten). Zeilen mit @@EMBED:...@@ nicht anfassen.
- tools/build_setup.py: baut aus setup_template.sh und chat/ die Datei setup_all.sh. Laeuft im Build automatisch.
- tools/smoke_test.py: Probelauf des Chat-Servers mit nachgebautem Sprachmodell. Laeuft bei "build_setup.py --check" mit.
- tools/unit_test.py: Einzeltests (edit_file, Verlauf kuerzen, Dev-Server-Werkzeuge, Bildabgleich). Laeuft bei "build_setup.py --check" mit.
- KIStart.swift: Starter-App fuer iPhone (SwiftUI). project.yml gehoert dazu.
- app.html: Starter-App fuer Android und Windows (eine Datei). main.js, package.json, capacitor.config.json sind die Huelle.
- .github/workflows/build.yml: baut ipa, apk und exe und legt sie im Release latest-<branch> ab.
- license/: Lizenz-Server (worker.js), seine Einstellungen und config.json mit der Server-Adresse. Test: "node tools/license_test.mjs".
- web/: alter Stand, wird nicht gebaut. Nicht aendern.
- Dev-Server: eigene Startart in beiden Starter-Apps (mode "dev"). Der Pod bekommt DEV_SERVER=1. Dann laedt setup_template.sh nur das Programmier-Modell (kein Bildteil), chat/server.py setzt die Klasse "dz" ans html-Element, und chat/index.html zeigt damit das gruene Aussehen (Regeln "html.dz ...") und oeffnet den Dev-Dialog von selbst.
- Bild-Server: eigene Startart (mode "img", env IMG_SERVER=1). Der Pod laedt nur Qwen-Image-Edit-2511 (GGUF) + Text-Encoder + VAE, kein LLM. chat/server.py baut den Qwen-Edit-Graphen (graph_qwen_edit) und hat im Bild-Server-Modus einen direkten Bearbeiten-Pfad ohne LLM; die Oberflaeche traegt die Klasse "imgsrv" (blau). Einzelne 48-GB-GPU reicht. ComfyUI-Graph ist noch nicht auf einem echten Pod getestet.
- Dev-Volume: Der Dev-Server kann ein eigenes Network Volume "ki-dev-vol" nutzen (Schalter in den Starter-Apps). Das normale Volume heisst "ki-chat-vol". Beide werden ueber den Namen gefunden.
- Vorschau (Werkzeug preview): Der Chat-Server liefert Projektdateien nur ueber einen geheimen Link und abgeschottet aus (Kopfzeile Content-Security-Policy: sandbox). Das nicht aufweichen, sonst kann eine Vorschau-Seite das Dev-Passwort lesen.
- devzone.mp4 (Hochformat) und devzone_wide.mp4 (Querformat, fuer breite Fenster): Intro "Satanic Dev Zone". Laeuft in den Starter-Apps beim ersten Oeffnen des Chats auf dem Dev-Server.

## Regeln
- Aenderungen am Chat (Verhalten, Werkzeuge, Oberflaeche): nur chat/server.py und chat/index.html.
- setup_all.sh und setup_full.sh nie anlegen, bearbeiten oder pushen. Die Dateien werden erzeugt.
- Nichts aus Base64 entpacken: alle Quelltexte liegen als normale Dateien vor.
- Nach jeder Aenderung pruefen: check (Syntax der geaenderten Dateien), dann run_tests (fuehrt "python3 tools/build_setup.py --check" samt Probelauf aus).
- Setup-Skript: Die App schickt nur ein kleines Start-Skript mit. Das volle Setup-Skript (setup_full.sh) legt der Build auf dem Lizenz-Server ab (Schluessel setup:<branch>), der Pod laedt es von dort mit dem Lizenz-Key (LICENSE_KEY). Die alte Groessengrenze gilt damit nicht mehr. Trotzdem nichts Unnoetiges in chat/ einbauen. Ohne Lizenz-Server in license/config.json steckt das volle Skript wie frueher in der App, dann gilt die Grenze wieder.
- Fertig heisst: git_push, danach build_status. Die ipa, apk und exe entstehen dabei automatisch, nichts von Hand uebertragen.
- git_push geht hier auf den Arbeitszweig satanic-dev, nie auf main. Der Build dazu liegt im Release latest-satanic-dev. Nach main uebernehmen kann nur der Nutzer ueber den Link, den git_push nennt.
- In run kein git push, pull, fetch, merge oder rebase: git_clone holt den neuesten Stand, git_push gleicht selbst ab. Bei einem Konflikt: git_clone mit fresh=true, dann die Aenderung neu einbauen.
- .github/workflows nur aendern, wenn der Nutzer es ausdruecklich verlangt.
- Will der Nutzer die fertige ipa, apk oder exe: get_build aufrufen (alle drei in einem ZIP: zip=true). Nie selbst mit curl oder gh herunterladen.
- Vorhandene Dateien (ZIP, Bilder, Binaerdateien) mit send_file uebergeben. create_file kann nur Text und PDF.
- Build-Dateien nicht entpacken oder pruefen. Icons in einer ipa liegen in einem Apple-eigenen PNG-Format, das sich hier nicht lesen laesst. Ein erfolgreicher Build ist der Nachweis.
- App-Icon: icon.png im Hauptordner, 1024x1024 PNG. Nur diese Datei ersetzen, der Build verteilt sie auf ipa, apk und exe.
- Vor git_push mit "git status --short" pruefen, dass nur gewollte Dateien geaendert sind, oder bei git_push files angeben.
- Zugangs-Token nie in Befehle, Dateien oder Notizen schreiben.
- Lizenz: Der Text LICENSE_SERVER_PLACEHOLDER in KIStart.swift und app.html muss stehen bleiben. Die Server-Adresse gehoert nur in license/config.json; der Build setzt sie ein. Leer heisst: Pruefung aus.
- Der Build legt die Dateien direkt ins Release (latest-<branch>), nicht mehr in den Build-Speicher von GitHub.
- Bild oder Dokument aus dem Chat: mit use_upload ins Projekt legen, nicht auf dem Server danach suchen.
- git_push prueft vor dem Push die Syntax und fuehrt hier zusaetzlich "tools/build_setup.py --check" samt Probelauf aus. Schlaegt das fehl, wird nichts gepusht.
- Aenderungen an chat/server.py sind heikel: ein Fehler legt den Chat lahm. Kleine Schritte, nach jedem Schritt pruefen.
- Build ohne Code-Fehler gescheitert (Aussetzer bei GitHub): build_rerun statt eines leeren Commits.
- Loeschen, Verschieben, Umbenennen: mit run (rm, mv). Letzten Commit zuruecknehmen: run "git revert --no-edit HEAD", danach git_push.
- Grosse Dateien (chat/server.py, chat/index.html, KIStart.swift, app.html) nie komplett lesen: erst outline oder search, dann read_file ab der gefundenen Zeile. Funde mit note festhalten.
- chat/server.py darf nur die Python-Standardbibliothek nutzen (auf dem Pod wird nichts nachinstalliert). Einzige Ausnahme: der Bildabgleich des Bild-Servers (keep_original, _align, _match_color) nutzt Pillow und numpy aus ComfyUI und faellt ohne sie auf das alte Verhalten zurueck.
