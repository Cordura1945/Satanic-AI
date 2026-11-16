import SwiftUI
import SafariServices
import Security
import AVFoundation
import WebKit
import CryptoKit
import UserNotifications

// MARK: - Speicher fuer Zugangsdaten (Schluesselbund, Ersatz: UserDefaults)
enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: key,
                                   kSecAttrService as String: "kistart"]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "kc_" + key)
        if value.isEmpty { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            UserDefaults.standard.set(value, forKey: "kc_" + key)
        }
    }
    static func get(_ key: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecAttrService as String: "kistart",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        return UserDefaults.standard.string(forKey: "kc_" + key) ?? ""
    }
}

// MARK: - RunPod (GraphQL)
struct RPError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

struct RunPod {
    let key: String

    func gql(_ query: String) async throws -> (data: [String: Any], err: String?) {
        var req = URLRequest(url: URL(string: "https://api.runpod.io/graphql")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String((String(data: data, encoding: .utf8) ?? "").prefix(160)).replacingOccurrences(of: "\n", with: " ")
            throw RPError(text: "Ungueltige Antwort (HTTP \(code)) \(body)")
        }
        var errText: String? = nil
        if let errs = obj["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String { errText = m }
        let d = obj["data"] as? [String: Any]
        if d == nil, let e = errText { throw RPError(text: e) }
        return (d ?? [:], errText)
    }

    func rest(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "https://api.runpod.io" + path)!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        obj["_raw"] = String((String(data: data, encoding: .utf8) ?? "").prefix(300))
        return (code, obj)
    }

    static func q(_ s: String) -> String {
        if let d = try? JSONEncoder().encode(s), let t = String(data: d, encoding: .utf8) { return t }
        return "\"\""
    }

    static func deployMutation(gpu: String, image: String, disk: Int, hf: String, autoStop: Int, setupB64: String, volumeId: String? = nil, dc: String? = nil, idleMin: Int = 0, gpuCount: Int = 1, dev: Bool = false, lic: String = "") -> String {
        let cmd = "bash -c \"mkdir -p /workspace && echo $SETUP_B64 | base64 -d | gunzip > /workspace/setup_all.sh && cd /workspace && bash setup_all.sh 2>&1 | tee /workspace/setup.log; sleep infinity\""
        let devEnv = (dev ? ",{key:" + q("DEV_SERVER") + ",value:" + q("1") + "}" : "") + ",{key:" + q("LICENSE_KEY") + ",value:" + q(lic) + "}"
        let env = "[{key:\(q("HF_TOKEN")),value:\(q(hf))},{key:\(q("AUTO_STOP_H")),value:\(q(String(autoStop)))},{key:\(q("IDLE_STOP_MIN")),value:\(q(String(idleMin)))},{key:\(q("SETUP_B64")),value:\(q(setupB64))}\(devEnv)]"
        var vol = ""
        if let v = volumeId, !v.isEmpty { vol = "networkVolumeId:\(q(v)),"; if let d = dc, !d.isEmpty { vol += "dataCenterId:\(q(d))," } }
        return "mutation{podFindAndDeployOnDemand(input:{\(vol)cloudType:ALL,gpuCount:\(gpuCount),volumeInGb:0,containerDiskInGb:\(disk),minVcpuCount:2,minMemoryInGb:15,gpuTypeId:\(q(gpu)),name:\"ki-chat\",imageName:\(q(image)),dockerArgs:\(q(cmd)),ports:\"8000/http\",env:\(env)}){id costPerHr machineId}}"
    }
}

struct Vast {
    let key: String
    func req(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: URL(string: "https://console.vast.ai/api/v0" + path)!)
        r.httpMethod = method
        r.timeoutInterval = 40
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let b = body { r.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (code, obj)
    }
}

// MARK: - Zustand
enum Phase { case none, boot, setup, loading, ready }

@MainActor
final class Model: ObservableObject {
    @Published var apiKey: String { didSet { Keychain.set(apiKey, for: "apiKey") } }
    @Published var hfToken: String { didSet { Keychain.set(hfToken, for: "hfToken") } }
    @Published var vastKey: String { didSet { Keychain.set(vastKey, for: "vastKey") } }
    var prov = "rp"
    @Published var gpus: String { didSet { UserDefaults.standard.set(gpus, forKey: "gpus") } }
    @Published var image: String { didSet { UserDefaults.standard.set(image, forKey: "image") } }
    @Published var disk: Int { didSet { UserDefaults.standard.set(disk, forKey: "disk") } }
    @Published var autoStop: Int { didSet { UserDefaults.standard.set(autoStop, forKey: "autoStop") } }
    @Published var idleStop: Int { didSet { UserDefaults.standard.set(idleStop, forKey: "idleStop") } }
    @Published var mode: String { didSet { UserDefaults.standard.set(mode, forKey: "mode") } }
    @Published var volGB: Int { didSet { UserDefaults.standard.set(volGB, forKey: "volGB") } }
    @Published var dc: String { didSet { UserDefaults.standard.set(dc, forKey: "dc") } }
    @Published var volId: String? = nil
    @Published var volInfo = ""
    @Published var volDC = ""
    @Published var maxPrice: Double { didSet { UserDefaults.standard.set(maxPrice, forKey: "maxPrice") } }
    @Published var devMaxPrice: Double { didSet { UserDefaults.standard.set(devMaxPrice, forKey: "devMaxPrice") } }
    // Dev-Server mit eigenem Network Volume "ki-dev-vol" (Modell und Projekte bleiben gespeichert)
    @Published var devVol: Bool { didSet { UserDefaults.standard.set(devVol, forKey: "devVol") } }
    @Published var devVolGB: Int { didSet { UserDefaults.standard.set(devVolGB, forKey: "devVolGB") } }
    @Published var devDc: String { didSet { UserDefaults.standard.set(devDc, forKey: "devDc") } }
    @Published var devVolId: String? = nil
    @Published var devVolInfo = ""
    // Dev-Server: zuerst zwei 48-GB-GPUs, sonst eine 80-GB-GPU. "2x " heisst zwei GPUs im Pod.
    static let devGpus: [String] = ["2x NVIDIA A40", "2x NVIDIA RTX A6000", "2x NVIDIA L40", "NVIDIA A100 80GB PCIe", "2x NVIDIA L40S", "NVIDIA A100-SXM4-80GB", "2x NVIDIA RTX 6000 Ada Generation"]

    @Published var balance: Double? = nil
    @Published var spend: Double = 0
    @Published var phase: Phase = .none
    @Published var licenseKey: String { didSet { UserDefaults.standard.set(licenseKey, forKey: "licenseKey") } }
    @Published var licenseOK = false
    @Published var licenseMsg = ""
    var licenseReason = ""
    @Published var step = ""
    @Published var pct: Double = 0
    @Published var shown: Double = 0
    @Published var eta = ""
    private var upMin = 0
    private var tickTask: Task<Void, Never>? = nil
    private static let pb: [Double] = [0, 5, 12, 62, 85, 97, 100]
    private static let tm: [Double] = [0, 3, 5, 17, 25, 29, 30]
    private static let capB: [Double] = [5, 8, 12, 62, 85, 87, 92, 97, 100]

    private func tmin(_ p: Double) -> Double {
        for i in 1..<Model.pb.count where p <= Model.pb[i] {
            let f = (p - Model.pb[i - 1]) / (Model.pb[i] - Model.pb[i - 1])
            return Model.tm[i - 1] + f * (Model.tm[i] - Model.tm[i - 1])
        }
        return 30
    }

    func tick() {
        if phase == .none { shown = 0; eta = ""; return }
        if phase == .ready { shown = 100; eta = ""; return }
        shown = max(shown, pct)
        let cap = (Model.capB.first { $0 > pct } ?? 100) - 1
        if shown < cap { shown = min(cap, shown + max(0.01, (cap - shown) * 0.006)) }
        let rest = Model.tm[Model.tm.count - 1] - tmin(shown)
        if upMin > 45 { eta = "dauert länger als üblich" }
        else { eta = "noch ca. \(max(1, Int(rest.rounded()))) Min (Schätzung)" }
    }
    @Published var log: [String] = []
    @Published var info = ""
    @Published var message = ""
    @Published var busy = false
    @Published var chatURL: URL? = nil

    private var podId: String? = nil
    private var gpuUsed: String = UserDefaults.standard.string(forKey: "gpuUsed") ?? ""
    private var loop: Task<Void, Never>? = nil

    init() {
        let u = UserDefaults.standard
        apiKey = Keychain.get("apiKey")
        hfToken = Keychain.get("hfToken")
        vastKey = Keychain.get("vastKey")
        let gl = "NVIDIA A40\nNVIDIA RTX A6000\nNVIDIA L40S\nNVIDIA L40\nNVIDIA RTX 6000 Ada Generation"
        if !u.bool(forKey: "gpusV3") { u.set(gl, forKey: "gpus"); u.set(true, forKey: "gpusV3") }
        gpus = u.string(forKey: "gpus") ?? gl
        maxPrice = u.object(forKey: "maxPrice") as? Double ?? 0.60
        devMaxPrice = u.object(forKey: "devMaxPrice") as? Double ?? 1.25
        devVol = u.bool(forKey: "devVol")
        devVolGB = u.object(forKey: "devVolGB") as? Int ?? 60
        devDc = u.string(forKey: "devDc") ?? "EU-RO-1"
        mode = u.string(forKey: "mode") ?? "demand"
        volGB = u.object(forKey: "volGB") as? Int ?? 60
        dc = u.string(forKey: "dc") ?? "EU-RO-1"
        image = u.string(forKey: "image") ?? "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"
        disk = u.object(forKey: "disk") as? Int ?? 100
        autoStop = u.object(forKey: "autoStop") as? Int ?? 8
        idleStop = u.object(forKey: "idleStop") as? Int ?? 30
        licenseKey = u.string(forKey: "licenseKey") ?? ""
    }

    // MARK: - Lizenz-Check
    // Adresse des Lizenz-Servers. Der Build setzt sie aus license/config.json ein.
    // Solange dort keine https-Adresse steht, ist die Pruefung ausgeschaltet.
    static let licenseServer = "LICENSE_SERVER_PLACEHOLDER"
    var licenseActive: Bool { Self.licenseServer.hasPrefix("https://") }

    func checkLicense() async {
        guard licenseActive, let url = URL(string: Self.licenseServer + "/verify") else {
            licenseOK = true
            licenseMsg = "Lizenzprüfung ist ausgeschaltet."
            return
        }
        let u = UserDefaults.standard
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        licenseReason = ""
        if key.isEmpty {
            licenseOK = false
            licenseMsg = "Kein Lizenz-Key eingetragen."
            return
        }
        let payload: [String: String] = ["key": key, "device": Self.deviceID()]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 10
        var answered = false
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code < 500, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let valid = obj["valid"] as? Bool {
                answered = true
                licenseOK = valid
                if valid {
                    if (obj["test"] as? Bool) == true {
                        // Test-Lizenz: keine Offline-Frist, bei jedem Start wird online geprueft
                        u.set(key, forKey: "licenseTestKey")
                        u.removeObject(forKey: "licenseLastOK")
                        var bis = ""
                        if let ms = obj["until"] as? Double {
                            let f = DateFormatter()
                            f.dateFormat = "dd.MM. HH:mm"
                            bis = " bis " + f.string(from: Date(timeIntervalSince1970: ms / 1000))
                        }
                        licenseMsg = "Test-Lizenz gültig" + bis + "."
                    } else {
                        u.removeObject(forKey: "licenseTestKey")
                        u.set(Date(), forKey: "licenseLastOK")
                        u.set(key, forKey: "licenseLastKey")
                        licenseMsg = "Lizenz gültig."
                    }
                } else {
                    licenseReason = (obj["reason"] as? String) ?? "unbekannt"
                    u.removeObject(forKey: "licenseLastOK")
                    licenseMsg = licenseReason == "abgelaufen" ? "Test-Lizenz abgelaufen." : "Lizenz ungültig: \(licenseReason)"
                }
            }
        } catch {
            answered = false
        }
        if !answered {
            // Server nicht erreichbar: Test-Lizenzen gelten dann nicht, Voll-Lizenzen noch 7 Tage ab der letzten gueltigen Pruefung
            let last = u.object(forKey: "licenseLastOK") as? Date
            if u.string(forKey: "licenseTestKey") == key {
                licenseOK = false
                licenseMsg = "Test-Lizenz: keine Verbindung zum Lizenz-Server."
            } else if let last = last, u.string(forKey: "licenseLastKey") == key, Date().timeIntervalSince(last) < 7 * 86400 {
                licenseOK = true
                licenseMsg = "Offline – letzte gültige Lizenz wird akzeptiert (7 Tage)."
            } else {
                licenseOK = false
                licenseMsg = "Keine Verbindung zum Lizenz-Server."
            }
        }
    }

    // Prueft die Lizenz auch im laufenden Betrieb: ist eine Test-Lizenz abgelaufen, wird der Server beendet
    func licenseGate() async {
        guard licenseActive else { licenseOK = true; return }
        await checkLicense()
        if !licenseOK && licenseReason == "abgelaufen" && podId != nil {
            await terminate()
            message = "Test-Lizenz abgelaufen – der Server wurde beendet."
        }
    }

    static func deviceID() -> String {
        // Zufaellige Kennung dieser Installation: uebersteht Updates, aendert sich bei Neuinstallation
        let u = UserDefaults.standard
        if let d = u.string(forKey: "licenseDevice"), d.count >= 16 { return d }
        let d = UUID().uuidString + UUID().uuidString
        u.set(d, forKey: "licenseDevice")
        return d
    }

    func startLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.poll()
                let secs: UInt64 = self.podId == nil ? 20 : 6
                try? await Task.sleep(nanoseconds: secs * 1_000_000_000)
            }
        }
    }

    func stopLoop() { loop?.cancel(); tickTask?.cancel() }

    func poll() async {
        if apiKey.isEmpty && vastKey.isEmpty {
            message = "Unten im Bereich Einstellungen den RunPod- oder Vast.ai-Key eintragen."
            return
        }
        var found = false
        if !apiKey.isEmpty { found = await pollRP() }
        if !found && !vastKey.isEmpty { await pollVast() }
    }

    private func resetIdle() {
        podId = nil; phase = .none; info = ""; step = ""; log = []; chatURL = nil; pct = 0; shown = 0; eta = ""; upMin = 0
    }

    func pollVast() async {
        do {
            let v = Vast(key: vastKey)
            let (_, lst) = try await v.req("GET", "/instances/")
            let list = lst["instances"] as? [[String: Any]] ?? []
            guard let ins = list.first(where: { ($0["label"] as? String) == "ki-chat" }),
                  let idn = (ins["id"] as? NSNumber)?.intValue else { resetIdle(); return }
            prov = "vast"
            podId = String(idn)
            if let (_, me) = try? await v.req("GET", "/users/current/"),
               let c = (me["credit"] as? NSNumber) ?? (me["balance"] as? NSNumber) { balance = c.doubleValue }
            let cost = (ins["dph_total"] as? NSNumber)?.doubleValue ?? 0
            spend = cost
            let sd = (ins["start_date"] as? NSNumber)?.doubleValue ?? 0
            let secs = sd > 0 ? max(0, Int(Date().timeIntervalSince1970 - sd)) : 0
            upMin = secs / 60
            info = (gpuUsed.isEmpty ? "Vast.ai · " : gpuUsed + " · ") + String(format: "$%.2f/h", cost) + " · \(secs / 3600) h \((secs % 3600) / 60) min" + String(format: " · Sitzung ca. $%.2f", cost * Double(secs) / 3600)
            let ip = ((ins["public_ipaddr"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var port = ""
            if let ports = ins["ports"] as? [String: Any], let arr = ports["8000/tcp"] as? [[String: Any]], let hp = arr.first?["HostPort"] as? String { port = hp }
            let running = (ins["actual_status"] as? String) == "running"
            guard running, !ip.isEmpty, !port.isEmpty else {
                phase = .boot; chatURL = nil; log = []; pct = max(pct, 2)
                step = "Vast.ai-Instanz startet (Image laden, 2–10 Min)…"
                return
            }
            let base = "http://\(ip):\(port)"
            var st: [String: Any]? = nil
            if let u = URL(string: base + "/api/status") {
                var r = URLRequest(url: u)
                r.timeoutInterval = 8
                if let res = try? await URLSession.shared.data(for: r),
                   let http = res.1 as? HTTPURLResponse, http.statusCode == 200 {
                    st = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any]
                }
            }
            if let st = st, st["llm"] != nil {
                let llm = st["llm"] as? Bool ?? false
                let comfy = st["comfy"] as? Bool ?? false
                chatURL = URL(string: base + "/")
                log = []
                if llm && comfy { phase = .ready; step = "Alles bereit."; pct = 100 }
                else { phase = .loading; step = "Modelle laden… LLM \(llm ? "✓" : "…")  Bild \(comfy ? "✓" : "…")"; pct = max(pct, llm || comfy ? 98 : 97) }
            } else if let st = st, let l = st["log"] as? [String] {
                phase = .setup; log = l; chatURL = nil
                step = "\(st["label"] as? String ?? "Setup")…"
                pct = max(pct, (st["pct"] as? NSNumber)?.doubleValue ?? 8)
            } else {
                phase = .boot; chatURL = nil; log = []; pct = max(pct, 5)
                step = "Container läuft, Setup startet…"
            }
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            message = "Vast.ai-Fehler: \(error.localizedDescription)"
        }
    }

    func pollRP() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        do {
            let (d, _) = try await RunPod(key: apiKey).gql("query{myself{clientBalance currentSpendPerHr networkVolumes{id name size dataCenterId} pods{id name desiredStatus costPerHr runtime{uptimeInSeconds}}}}")
            guard let me = d["myself"] as? [String: Any] else { return true }
            balance = (me["clientBalance"] as? NSNumber)?.doubleValue
            spend = (me["currentSpendPerHr"] as? NSNumber)?.doubleValue ?? 0
            let vols = me["networkVolumes"] as? [[String: Any]] ?? []
            if let v = vols.first(where: { ($0["name"] as? String) == "ki-chat-vol" }) {
                volId = v["id"] as? String
                let sz = (v["size"] as? NSNumber)?.intValue ?? 0
                volInfo = "\(sz) GB · \(v["dataCenterId"] as? String ?? "?") · ca. $\(String(format: "%.2f", Double(sz) * 0.07))/Monat"
                volDC = v["dataCenterId"] as? String ?? ""
            } else { volId = nil; volInfo = ""; volDC = "" }
            if let v = vols.first(where: { ($0["name"] as? String) == "ki-dev-vol" }) {
                devVolId = v["id"] as? String
                let sz = (v["size"] as? NSNumber)?.intValue ?? 0
                devVolInfo = "\(sz) GB · \(v["dataCenterId"] as? String ?? "?") · ca. $\(String(format: "%.2f", Double(sz) * 0.07))/Monat"
            } else { devVolId = nil; devVolInfo = "" }
            let pods = me["pods"] as? [[String: Any]] ?? []
            guard let pod = pods.first(where: { ($0["name"] as? String) == "ki-chat" && ($0["desiredStatus"] as? String) == "RUNNING" }),
                  let id = pod["id"] as? String else {
                resetIdle()
                return false
            }
            prov = "rp"
            podId = id
            let cost = (pod["costPerHr"] as? NSNumber)?.doubleValue ?? 0
            var up = ""
            if let rt = pod["runtime"] as? [String: Any], let s = (rt["uptimeInSeconds"] as? NSNumber)?.intValue {
                up = " · \(s / 3600) h \((s % 3600) / 60) min" + String(format: " · Sitzung ca. $%.2f", cost * Double(s) / 3600)
                upMin = s / 60
            }
            info = (gpuUsed.isEmpty ? "" : gpuUsed + " · ") + String(format: "$%.2f/h", cost) + up
            let base = "https://\(id)-8000.proxy.runpod.net"
            var st: [String: Any]? = nil
            if let u = URL(string: base + "/api/status") {
                var r = URLRequest(url: u)
                r.timeoutInterval = 8
                if let res = try? await URLSession.shared.data(for: r),
                   let http = res.1 as? HTTPURLResponse, http.statusCode == 200 {
                    st = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any]
                }
            }
            if let st = st, st["llm"] != nil {
                let llm = st["llm"] as? Bool ?? false
                let comfy = st["comfy"] as? Bool ?? false
                chatURL = URL(string: base + "/")
                log = []
                if llm && comfy { phase = .ready; step = "Alles bereit."; pct = 100 }
                else { phase = .loading; step = "Modelle laden… LLM \(llm ? "✓" : "…")  Bild \(comfy ? "✓" : "…")"; pct = max(pct, llm || comfy ? 98 : 97) }
            } else if let st = st, let l = st["log"] as? [String] {
                phase = .setup; log = l; chatURL = nil
                let lab = st["label"] as? String ?? "Setup"
                step = "\(lab)…"
                let np = (st["pct"] as? NSNumber)?.doubleValue ?? 8
                pct = max(pct, np)
            } else {
                phase = .boot; chatURL = nil; log = []
                pct = max(pct, pod["runtime"] is NSNull || pod["runtime"] == nil ? 2 : 5)
                step = pod["runtime"] is NSNull || pod["runtime"] == nil ? "Pod wird gestartet (Image laden, 2–5 Min)…" : "Container läuft, Setup startet…"
            }
            return true
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return true }
            message = "RunPod-Fehler: \(error.localizedDescription)"
            return true
        }
    }

    // MARK: - Autostart: wiederholt den Start, bis ein Pod laeuft oder der Nutzer abbricht
    @Published var autoRun = false
    @Published var autoInfo = ""
    private var retryable = false
    // GPUs, die ueber dem Preislimit lagen, werden waehrend des Autostarts 10 Minuten uebersprungen,
    // damit nicht staendig teure Pods angelegt und gleich wieder beendet werden.
    private var skipUntil: [String: Date] = [:]

    func autoStart() async {
        guard !autoRun, !busy else { return }
        autoRun = true
        skipUntil = [:]
        UIApplication.shared.isIdleTimerDisabled = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        keepAlive(true)
        var n = 0
        while autoRun {
            n += 1
            // Lizenz am Anfang und dann etwa alle 100 Versuche pruefen, nicht alle 3 Sekunden
            if n % 100 == 1 {
                await checkLicense()
                if !licenseOK { licenseMsg = "Lizenz ungültig – Start blockiert. Bitte Lizenz-Key prüfen."; break }
            }
            retryable = false
            autoInfo = n == 1 ? "" : "Autostart: Versuch \(n) läuft…"
            await start()
            if podId != nil {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if UIApplication.shared.applicationState != .active {
                    let c = UNMutableNotificationContent()
                    c.title = "Satanic"
                    c.body = "Server gefunden (\(gpuUsed)), Pod startet."
                    c.sound = .default
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pod-gefunden", content: c, trigger: nil))
                }
                break
            }
            if !retryable { break }
            autoInfo = "Autostart: Versuch \(n) ohne passende GPU, suche weiter…"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        autoRun = false
        autoInfo = ""
        UIApplication.shared.isIdleTimerDisabled = false
        keepAlive(false)
    }

    // Im Hintergrund pausiert iOS die App. Damit die Suche weiterlaeuft, spielt die App waehrend des
    // Autostarts lautlose Stille ab (Hintergrundmodus "audio", siehe project.yml). Andere Musik laeuft weiter.
    private var silence: AVAudioPlayer? = nil
    private func keepAlive(_ on: Bool) {
        if !on { silence?.stop(); silence = nil; return }
        let sr: UInt32 = 8000
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + sr * 2); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(sr * 2); d.append(Data(count: Int(sr * 2)))
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        silence = try? AVAudioPlayer(data: d)
        silence?.numberOfLoops = -1
        silence?.play()
    }

    func stopAuto() {
        autoRun = false
        autoInfo = ""
    }

    func start() async {
        guard !busy else { return }
        guard !(apiKey.isEmpty && vastKey.isEmpty), !hfToken.isEmpty else {
            message = "RunPod- oder Vast.ai-Key und Hugging-Face-Token eintragen."
            return
        }
        guard let url = Bundle.main.url(forResource: "setup_all.sh", withExtension: "gz"),
              let data = try? Data(contentsOf: url) else {
            message = "setup_all.sh fehlt im App-Paket."
            return
        }
        busy = true
        defer { busy = false }
        let b64 = data.base64EncodedString()
        var errs: [String] = []
        var useVol: String? = nil
        var useDC: String? = nil
        let devMode = mode == "dev"
        let volName = devMode ? "ki-dev-vol" : "ki-chat-vol"
        let volSize = devMode ? devVolGB : volGB
        let volWant = devMode ? devDc.trimmingCharacters(in: .whitespaces).uppercased() : dc
        if (mode == "volume" || (devMode && devVol)) && !apiKey.isEmpty {
            message = "Network Volume wird vorbereitet…"
            do {
                let rp = RunPod(key: apiKey)
                let (d0, _) = try await rp.gql("query{myself{networkVolumes{id name size dataCenterId}}}")
                let vs = (d0["myself"] as? [String: Any])?["networkVolumes"] as? [[String: Any]] ?? []
                if let v = vs.first(where: { ($0["name"] as? String) == volName }), let id = v["id"] as? String {
                    useVol = id; useDC = v["dataCenterId"] as? String
                } else {
                    let (code, obj) = try await rp.rest("POST", "/v2/network-volumes", ["name": volName, "dataCenter": volWant, "size": volSize])
                    if let id = obj["id"] as? String {
                        useVol = id; useDC = (obj["dataCenter"] as? String) ?? volWant
                    } else {
                        let em = (obj["message"] as? String) ?? (obj["error"] as? String) ?? (obj["_raw"] as? String) ?? "keine Details"
                        message = "Volume konnte nicht erstellt werden (HTTP \(code)): \(em)"
                        return
                    }
                }
            } catch {
                message = "Volume-Fehler: \(error.localizedDescription)"
                return
            }
        }
        let dev = mode == "dev"
        var over: [String] = []
        let licKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let limit = dev ? devMaxPrice : maxPrice
        let list: [String] = dev ? Model.devGpus : gpus.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for entry in (apiKey.isEmpty ? [] : list) {
            let n = entry.hasPrefix("2x ") ? 2 : 1
            let g = n == 2 ? String(entry.dropFirst(3)) : entry
            if let t = skipUntil[entry], t > Date() {
                over.append(entry)
                continue
            }
            message = "Versuche \(entry)…"
            do {
                let m = RunPod.deployMutation(gpu: g, image: image, disk: dev ? max(disk, 80) : disk, hf: hfToken, autoStop: autoStop, setupB64: b64, volumeId: useVol, dc: useDC, idleMin: idleStop, gpuCount: n, dev: dev, lic: licKey)
                let (d, err) = try await RunPod(key: apiKey).gql(m)
                if let p = d["podFindAndDeployOnDemand"] as? [String: Any], let id = p["id"] as? String {
                    let c = (p["costPerHr"] as? NSNumber)?.doubleValue ?? 0
                    if limit > 0 && c > limit {
                        _ = try? await RunPod(key: apiKey).gql("mutation{podTerminate(input:{podId:\(RunPod.q(id))})}")
                        errs.append("\(entry): $\(String(format: "%.2f", c))/h > Limit, Pod wieder beendet")
                        skipUntil[entry] = Date().addingTimeInterval(600)
                        over.append("\(entry) ($\(String(format: "%.2f", c))/h)")
                        continue
                    }
                    podId = id
                    gpuUsed = g
                    UserDefaults.standard.set(g, forKey: "gpuUsed")
                    message = "Pod erstellt: \(g)"
                    await poll()
                    return
                }
                errs.append("\(g): \(err ?? "keine Antwort")")
            } catch {
                errs.append("\(g): \(error.localizedDescription)")
            }
        }
        if !vastKey.isEmpty && !dev {
            await startVast(b64: b64, errs: errs)
            return
        }
        let hint = over.isEmpty ? "" : "Über deinem Preislimit von $\(String(format: "%.2f", limit))/h und deshalb ausgelassen: " + over.joined(separator: ", ") + ". Limit in den Einstellungen erhöhen, wenn du sie nutzen willst.\n\n"
        message = hint + "Keine GPU frei oder Fehler:\n" + errs.joined(separator: "\n")
        retryable = true
    }

    func startVast(b64: String, errs prev: [String]) async {
        var errs = prev
        message = "RunPod hat keine GPU frei – versuche Vast.ai…"
        let v = Vast(key: vastKey)
        var q: [String: Any] = ["verified": ["eq": true], "rentable": ["eq": true], "rented": ["eq": false], "num_gpus": ["eq": 1],
                                "gpu_ram": ["gte": 44000], "disk_space": ["gte": disk], "direct_port_count": ["gte": 1],
                                "cuda_max_good": ["gte": 12.8], "inet_down": ["gte": 300], "reliability": ["gte": 0.95],
                                "order": [["dph_total", "asc"]], "type": "on-demand", "limit": 8]
        if maxPrice > 0 { q["dph_total"] = ["lte": maxPrice] }
        let onstart = "mkdir -p /workspace\necho \"$SETUP_B64\" | base64 -d | gunzip > /workspace/setup_all.sh\ncd /workspace\nnohup bash setup_all.sh > /workspace/setup.log 2>&1 &\n"
        let env: [String: Any] = ["HF_TOKEN": hfToken, "AUTO_STOP_H": String(autoStop), "IDLE_STOP_MIN": String(idleStop), "SETUP_B64": b64, "LICENSE_KEY": licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), "-p 8000:8000": "1"]
        do {
            let (code, o) = try await v.req("POST", "/bundles/", q)
            let offers = o["offers"] as? [[String: Any]] ?? []
            if offers.isEmpty { errs.append("Vast.ai: keine passende GPU im Preislimit (HTTP \(code))") }
            for off in offers.prefix(5) {
                guard let oid = (off["id"] as? NSNumber)?.intValue else { continue }
                let gname = off["gpu_name"] as? String ?? "GPU"
                let price = (off["dph_total"] as? NSNumber)?.doubleValue ?? 0
                message = "Vast.ai: \(gname) · $\(String(format: "%.2f", price))/h …"
                let body: [String: Any] = ["image": image, "disk": disk, "label": "ki-chat", "runtype": "ssh_direct", "onstart": onstart, "env": env]
                let (c2, r) = try await v.req("PUT", "/asks/\(oid)/", body)
                if (r["success"] as? Bool) == true, let nc = (r["new_contract"] as? NSNumber)?.intValue {
                    prov = "vast"; podId = String(nc)
                    gpuUsed = "Vast.ai · " + gname
                    UserDefaults.standard.set(gpuUsed, forKey: "gpuUsed")
                    message = "Vast.ai gestartet: \(gname)"
                    await poll()
                    return
                }
                errs.append("Vast.ai \(gname): \((r["msg"] as? String) ?? (r["error"] as? String) ?? "HTTP \(c2)")")
            }
        } catch {
            errs.append("Vast.ai: \(error.localizedDescription)")
        }
        message = "Keine GPU frei oder Fehler:\n" + errs.joined(separator: "\n")
        retryable = true
    }

    func deleteVolume(dev: Bool = false) async {
        guard let id = dev ? devVolId : volId else { return }
        do {
            let (code, obj) = try await RunPod(key: apiKey).rest("DELETE", "/v2/network-volumes/\(id)")
            if (200...299).contains(code) { message = "Volume gelöscht." }
            else { message = "Löschen fehlgeschlagen (HTTP \(code)): \((obj["message"] as? String) ?? "bitte in der RunPod-Konsole löschen")" }
        } catch {
            message = "Fehler beim Löschen: \(error.localizedDescription)"
        }
        await poll()
    }

    func terminate() async {
        guard let id = podId else { return }
        do {
            if prov == "vast" {
                let (c, _) = try await Vast(key: vastKey).req("DELETE", "/instances/\(id)/")
                if !(200...299).contains(c) { message = "Vast.ai: Beenden fehlgeschlagen (HTTP \(c)). Bitte in der Vast.ai-Konsole löschen." ; return }
            } else {
                _ = try await RunPod(key: apiKey).gql("mutation{podTerminate(input:{podId:\(RunPod.q(id))})}")
            }
            message = "Pod beendet."
            podId = nil
            phase = .none
        } catch {
            message = "Fehler beim Beenden: \(error.localizedDescription)"
        }
        await poll()
    }
}

// MARK: - Oberflaeche
struct WebLink: Identifiable {
    let id = UUID()
    let url: URL
}

func topViewController() -> UIViewController? {
    var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    while let p = top?.presentedViewController { top = p }
    return top
}

struct ChatWebView: UIViewRepresentable {
    let url: URL
    let onClose: () -> Void
    let onNoBack: (Bool) -> Void

    func makeCoordinator() -> Coord { Coord(onClose: onClose, onNoBack: onNoBack) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.applicationNameForUserAgent = "KIStartApp"
        cfg.userContentController.add(context.coordinator, name: "close")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        let bg = UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        wv.backgroundColor = bg
        wv.scrollView.backgroundColor = bg
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        let onClose: () -> Void
        let onNoBack: (Bool) -> Void
        var dest: URL?
        init(onClose: @escaping () -> Void, onNoBack: @escaping (Bool) -> Void) {
            self.onClose = onClose
            self.onNoBack = onNoBack
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if m.name == "close" { DispatchQueue.main.async { self.onClose() } }
        }

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            w.evaluateJavaScript("!!document.getElementById('back')") { r, _ in
                DispatchQueue.main.async { self.onNoBack(!((r as? Bool) ?? false)) }
            }
        }

        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            DispatchQueue.main.async { self.onNoBack(true) }
        }

        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Downloads im Browser oeffnen: dort gibt es die Abfrage "Laden" und eine Fortschrittsanzeige.
            if a.shouldPerformDownload, let u = a.request.url {
                decisionHandler(.cancel)
                DispatchQueue.main.async { UIApplication.shared.open(u) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let att = ((r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment")
            if att || !r.canShowMIMEType, let u = r.response.url {
                decisionHandler(.cancel)
                DispatchQueue.main.async { UIApplication.shared.open(u) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
        func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }

        func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent(suggestedFilename)
            dest = u
            completionHandler(u)
        }

        func downloadDidFinish(_ d: WKDownload) {
            guard let u = dest else { return }
            DispatchQueue.main.async {
                let vc = UIActivityViewController(activityItems: [u], applicationActivities: nil)
                topViewController()?.present(vc, animated: true)
            }
        }

        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if a.targetFrame == nil { w.load(a.request) }
            return nil
        }

        func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let al = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            al.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            topViewController()?.present(al, animated: true)
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

enum Theme {
    static let gold = Color(red: 0.90, green: 0.69, blue: 0.23)
    static let red = Color(red: 0.88, green: 0.34, blue: 0.31)
    static let green = Color(red: 0.29, green: 0.82, blue: 0.50)
    static let blue = Color(red: 0.35, green: 0.65, blue: 0.88)
    static let gray = Color(red: 0.54, green: 0.54, blue: 0.59)
    static let dim = Color(red: 0.23, green: 0.23, blue: 0.27)
    static let line = Color(red: 0.17, green: 0.17, blue: 0.21)
    static let panel = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let bar = Color(red: 0.10, green: 0.10, blue: 0.13)
    static let rose = Color(red: 0.62, green: 0.19, blue: 0.19)
    static let card = Color(red: 0.11, green: 0.05, blue: 0.07)
    static let bgTop = Color(red: 0.03, green: 0.02, blue: 0.05)
    static let bgBottom = Color(red: 0.16, green: 0.03, blue: 0.04)
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        Font.system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
    }
}

struct Card<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.green : Theme.line, lineWidth: selected ? 1.5 : 1))
    }
}

struct Field: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(10).font(Theme.mono(13)).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }
}

struct ProgressBar: View {
    let value: Double
    var eta: String = ""
    var barText: Text {
        let v = min(max(value, 0), 100)
        let n = 24
        let f = Int((v / 100 * Double(n)).rounded())
        let a: Text = Text("[").foregroundColor(Theme.gray)
        let b: Text = Text(String(repeating: "#", count: f)).foregroundColor(Theme.red)
        let c: Text = Text(String(repeating: "-", count: n - f)).foregroundColor(Theme.dim)
        let d: Text = Text("] ").foregroundColor(Theme.gray)
        let e: Text = Text("\(Int(v))%").foregroundColor(Theme.gold)
        return a + b + c + d + e
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            barText.font(Theme.mono(14, bold: true)).lineLimit(1).minimumScaleFactor(0.6)
            if !eta.isEmpty { Text(eta).font(Theme.mono(12)).foregroundColor(Theme.gray) }
        }
    }
}

struct GoldButton: View {
    let title: String
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("[ " + title + " ]").font(Theme.mono(16, bold: true)).foregroundColor(danger ? Theme.red : Theme.green)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(danger ? Theme.red : Theme.green, lineWidth: 1.5))
        }
    }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {}
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

struct ContentView: View {
    @StateObject private var m = Model()
    @Environment(\.scenePhase) private var scene
    @State private var web: WebLink? = nil
    @State private var confirmStop = false
    @State private var confirmVol = false
    @State private var confirmDevVol = false
    @State private var showSettings = false
    @State private var noBack = false
    @State private var player: AVPlayer? = nil
    @State private var videoOpacity = 1.0
    @State private var uiOpacity = 0.0
    @State private var introStarted = false
    @State private var dzPlayer: AVPlayer? = nil
    @State private var dzURL: URL? = nil
    @State private var dzSeen = false

    // Dev-Server: beim ersten Oeffnen des Chats laeuft das Intro "Satanic Dev Zone" (Tippen ueberspringt)
    func openChat(_ u: URL) {
        guard m.mode == "dev", !dzSeen, dzPlayer == nil, let v = Bundle.main.url(forResource: "devzone", withExtension: "mp4") else { web = WebLink(url: u); return }
        dzSeen = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: v)
        dzURL = u
        dzPlayer = p
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in finishDevIntro() }
        p.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) { finishDevIntro() }
    }

    func finishDevIntro() {
        guard let p = dzPlayer, let u = dzURL else { return }
        p.pause()
        dzPlayer = nil
        dzURL = nil
        web = WebLink(url: u)
    }

    func startIntro() {
        guard !introStarted else { return }
        introStarted = true
        guard let url = Bundle.main.url(forResource: "splash", withExtension: "mp4") else {
            videoOpacity = 0; uiOpacity = 1; return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let p = AVPlayer(url: url)
        player = p
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in finishIntro() }
        p.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            withAnimation(.easeInOut(duration: 4)) { uiOpacity = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { finishIntro() }
    }

    func finishIntro() {
        withAnimation(.easeOut(duration: 0.8)) { videoOpacity = 0; uiOpacity = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { player?.pause() }
    }

    var title: String {
        switch m.phase {
        case .none: return "Kein Pod"
        case .boot: return "Pod startet"
        case .setup: return "Setup läuft"
        case .loading: return "Modelle laden"
        case .ready: return "Bereit"
        }
    }

    var volMonth: String { String(format: "%.2f", Double(m.volGB) * 0.07) }

    static let banner = " ███████  █████  ████████  █████  ███    ██ ██  ██████\n ██      ██   ██    ██    ██   ██ ████   ██ ██ ██     \n ███████ ███████    ██    ███████ ██ ██  ██ ██ ██     \n      ██ ██   ██    ██    ██   ██ ██  ██ ██ ██ ██     \n ███████ ██   ██    ██    ██   ██ ██   ████ ██  ██████"

    var promptLine: Text {
        let a: Text = Text("root@satanic").foregroundColor(Theme.green)
        let b: Text = Text(":").foregroundColor(Theme.gray)
        let c: Text = Text("~").foregroundColor(Theme.blue)
        let d: Text = Text("$ ").foregroundColor(Theme.gray)
        let e: Text = Text("./start.sh").foregroundColor(.white)
        return a + b + c + d + e
    }

    var statusColor: Color { (m.phase == .none || m.phase == .ready) ? Theme.green : Theme.gold }

    func modeCard(_ id: String, _ name: String, _ text: String) -> some View {
        Button { m.mode = id } label: {
            Card(selected: m.mode == id) {
                HStack(spacing: 8) {
                    Text(m.mode == id ? "(*)" : "( )").font(Theme.mono(15, bold: true)).foregroundColor(m.mode == id ? Theme.green : Theme.gray)
                    Text(name).font(Theme.mono(15, bold: true)).foregroundColor(.white)
                    Spacer()
                }
                Text(text).font(Theme.mono(11.5)).foregroundColor(Theme.gray).multilineTextAlignment(.leading)
            }
        }.buttonStyle(.plain)
    }

    var settingsBlock: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("API-Keys erstellen") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RunPod: Konto anlegen, Guthaben aufladen, dann im Bereich Settings oder Credentials einen API-Key erstellen (Rechte: Lesen und Schreiben). Der Key beginnt mit rpa_.")
                        Link(destination: URL(string: "https://console.runpod.io/user/settings")!) {
                            Text("[>] RunPod öffnen").foregroundColor(Theme.gold)
                        }
                        Text("Hugging Face: Konto anlegen, dann unter Settings → Access Tokens ein Token mit Leserechten (Read) erstellen. Es beginnt mit hf_. Damit lädt der Pod die Modelle.")
                        Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) {
                            Text("[>] Hugging Face öffnen").foregroundColor(Theme.gold)
                        }
                        Text("Beide Keys nie weitergeben oder im Chat posten. Sie liegen nur im Schlüsselbund dieses iPhones.")
                            .foregroundColor(Theme.gray)
                    }.padding(.top, 6)
                }.tint(Theme.gold)
                SecureField("Lizenz-Key", text: $m.licenseKey).modifier(Field())
                if !m.licenseMsg.isEmpty {
                    Text(m.licenseMsg).font(Theme.mono(11)).foregroundColor(m.licenseOK ? Theme.green : Theme.red)
                }
                Button("Lizenz prüfen") {
                    Task { await m.checkLicense() }
                }.font(Theme.mono(12)).foregroundColor(Theme.gold)
                SecureField("RunPod API-Key", text: $m.apiKey).modifier(Field())
                SecureField("Vast.ai API-Key (Ersatz, optional)", text: $m.vastKey).modifier(Field())
                SecureField("Hugging-Face-Token", text: $m.hfToken).modifier(Field())
                Stepper("Max. Preis: $\(String(format: "%.2f", m.maxPrice))/h", value: $m.maxPrice, in: 0...3, step: 0.05)
                Stepper("Max. Preis Dev-Server: $\(String(format: "%.2f", m.devMaxPrice))/h", value: $m.devMaxPrice, in: 0...6, step: 0.05)
                Stepper("Auto-Beenden: \(m.autoStop == 0 ? "aus" : "\(m.autoStop) h")", value: $m.autoStop, in: 0...48)
                Stepper("Leerlauf-Abschaltung: \(m.idleStop == 0 ? "aus" : "\(m.idleStop) Min")", value: $m.idleStop, in: 0...240, step: 5)
                Stepper("Disk: \(m.disk) GB", value: $m.disk, in: 60...300, step: 10)
                TextField("Rechenzentrum (nur Volume)", text: $m.dc).modifier(Field()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Docker-Image", text: $m.image).modifier(Field()).textInputAutocapitalization(.never).autocorrectionDisabled()
            }.padding(.top, 8).foregroundColor(.white).font(Theme.mono(12))
        } label: {
            Text("> EINSTELLUNGEN").font(Theme.mono(12, bold: true)).foregroundColor(Theme.green)
        }
        .tint(Theme.gold)
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    var podBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            if m.phase == .none {
                Text("> STARTART WÄHLEN").font(Theme.mono(12, bold: true)).foregroundColor(Theme.green)
                modeCard("demand", "On Demand",
                         "Alles wird bei jedem Start komplett neu heruntergeladen (ca. 10–25 Min Wartezeit, ca. 37 GB). Kein Dauerpreis, du zahlst nur die GPU-Zeit. Die Wartezeit kostet ca. $0.10–0.30 pro Start.")
                modeCard("volume", "Network Volume",
                         "Modelle bleiben gespeichert, spätere Starts dauern nur wenige Minuten. Kostet dauerhaft ca. $\(volMonth) pro Monat (\(m.volGB) GB, ca. $0.07/GB), auch wenn kein Pod läuft. Der erste Start lädt alles einmal. GPUs nur im Rechenzentrum des Volumes (\((m.volId != nil && !m.volDC.isEmpty) ? m.volDC : m.dc)).")
                modeCard("dev", "Dev-Server",
                         "Eigener Server nur zum Programmieren: großes Programmier-Modell (ca. 49 GB) auf 2× 48 GB oder 1× 80 GB Grafikspeicher, Dev-Modus und grüne Dev Zone, ohne Bildteil. Ohne Volume lädt jeder Start alles neu (ca. 15–30 Min), mit eigenem Dev-Volume nur der erste. Kostet ab ca. $1.20 pro Stunde. Eigenes Preislimit ($1.25) in den Einstellungen, für teurere GPUs dort erhöhen.")
                if m.mode == "dev" {
                    Card {
                        Toggle(isOn: $m.devVol) {
                            Text("Network Volume für den Dev-Server").font(Theme.mono(12, bold: true)).foregroundColor(.white)
                        }.tint(Theme.green)
                        if m.devVol {
                            if m.devVolId != nil {
                                Text("Vorhandenes Dev-Volume: \(m.devVolInfo)").font(Theme.mono(12)).foregroundColor(Theme.gray)
                                Button("[x] Dev-Volume löschen", role: .destructive) { confirmDevVol = true }.font(Theme.mono(12))
                            } else {
                                Stepper("Größe: \(m.devVolGB) GB (ca. $\(String(format: "%.2f", Double(m.devVolGB) * 0.07))/Monat)", value: $m.devVolGB, in: 55...200, step: 5)
                                    .foregroundColor(.white).font(Theme.mono(12))
                                TextField("Rechenzentrum, z.B. EU-RO-1", text: $m.devDc).modifier(Field()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            }
                            Text("Eigenes Volume „ki-dev-vol“: Modell und Projekte bleiben gespeichert, spätere Starts dauern nur wenige Minuten. Kostet dauerhaft, auch wenn kein Pod läuft. Mit Volume gibt es nur GPUs aus dessen Rechenzentrum. Es wird beim ersten Start angelegt, falls es noch fehlt.")
                                .font(Theme.mono(11.5)).foregroundColor(Theme.gray)
                        } else {
                            Text("Aus: On Demand, bei jedem Start wird alles neu geladen.").font(Theme.mono(11.5)).foregroundColor(Theme.gray)
                        }
                    }
                }
                if m.mode == "volume" {
                    Card {
                        if m.volId != nil {
                            Text("Vorhandenes Volume: \(m.volInfo)").font(Theme.mono(12)).foregroundColor(Theme.gray)
                            Button("[x] Volume löschen", role: .destructive) { confirmVol = true }.font(Theme.mono(12))
                        } else {
                            Stepper("Größe: \(m.volGB) GB (ca. $\(volMonth)/Monat)", value: $m.volGB, in: 50...300, step: 10)
                                .foregroundColor(.white).font(Theme.mono(12))
                        }
                    }
                }
                if m.autoRun {
                    GoldButton(title: "Autostart beenden", danger: true) { m.stopAuto() }
                    if !m.autoInfo.isEmpty {
                        Text(m.autoInfo).font(Theme.mono(12, bold: true)).foregroundColor(Theme.gold)
                    }
                } else {
                    GoldButton(title: m.busy ? "Starte…" : "Starten") {
                        Task { await m.autoStart() }
                    }.disabled(m.busy)
                }
            } else {
                Card {
                    Text(title).font(Theme.mono(17, bold: true)).foregroundColor(m.phase == .ready ? Theme.green : .white)
                    if !m.info.isEmpty { Text(m.info).font(Theme.mono(11.5)).foregroundColor(Theme.gray) }
                    ProgressBar(value: m.shown, eta: m.eta)
                    if !m.step.isEmpty { Text(m.step).font(Theme.mono(12)).foregroundColor(.white.opacity(0.9)) }
                    if !m.log.isEmpty {
                        Text(m.log.joined(separator: "\n")).font(Theme.mono(11)).foregroundColor(Theme.gray)
                    }
                }
                if let u = m.chatURL, m.phase == .loading || m.phase == .ready {
                    GoldButton(title: "Chat öffnen") {
                        Task {
                            await m.licenseGate()
                            if m.licenseOK { openChat(u) } else { m.message = m.licenseMsg }
                        }
                    }
                }
                GoldButton(title: "Beenden (Terminate)", danger: true) { confirmStop = true }
            }
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.045).ignoresSafeArea()
            RadialGradient(colors: [Color(red: 0.55, green: 0.08, blue: 0.10).opacity(0.34), Color.clear],
                           center: UnitPoint(x: 0.5, y: 0.12), startRadius: 0, endRadius: 520).ignoresSafeArea()
            if let p = player {
                PlayerView(player: p).ignoresSafeArea().opacity(videoOpacity).allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.red).frame(width: 11, height: 11)
                    Circle().fill(Theme.gold).frame(width: 11, height: 11)
                    Circle().fill(Theme.green).frame(width: 11, height: 11)
                    Spacer()
                    Text("satanic — python3").font(Theme.mono(12)).foregroundColor(Theme.gray)
                    Spacer()
                    Color.clear.frame(width: 47, height: 11)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Theme.bar)
                Rectangle().fill(Theme.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        promptLine.font(Theme.mono(14))
                        Card {
                            Text("> RUNPOD-GUTHABEN").font(Theme.mono(12, bold: true)).foregroundColor(Theme.green)
                            HStack(alignment: .firstTextBaseline) {
                                Text(m.balance.map { String(format: "$%.2f", $0) } ?? "–").font(Theme.mono(34, bold: true)).foregroundColor(Theme.gold)
                                Spacer()
                                Text(String(format: "Verbrauch: $%.2f/h", m.spend)).font(Theme.mono(12)).foregroundColor(Theme.gray)
                            }
                            if let b = m.balance, b < 2 { Text("Guthaben niedrig, bitte aufladen.").font(Theme.mono(12)).foregroundColor(Theme.red) }
                            Link(destination: URL(string: "https://console.runpod.io/user/billing")!) {
                                Text("[+] Guthaben aufladen").font(Theme.mono(14)).foregroundColor(Theme.gold)
                            }
                        }
                        podBlock
                        if !m.message.isEmpty { Text(m.message).font(Theme.mono(12)).foregroundColor(Theme.gray).frame(maxWidth: .infinity, alignment: .leading) }
                        settingsBlock
                        VStack(spacing: 6) {
                            Text(ContentView.banner).font(Theme.mono(8, bold: true)).foregroundColor(Theme.rose).lineLimit(5).minimumScaleFactor(0.5)
                            Text("uncensored ai · runpod").font(Theme.mono(10)).foregroundColor(Theme.dim)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 12)
                    }
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 30)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { hideKeyboard() }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(title.lowercased()).font(Theme.mono(12, bold: true)).foregroundColor(statusColor)
                    Spacer()
                    Text(String(format: "$%.2f/h", m.spend)).font(Theme.mono(12)).foregroundColor(Theme.gold)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.bar)
            }
            .background(Theme.panel.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .opacity(uiOpacity)
            .offset(y: (1 - uiOpacity) * 24)
            .allowsHitTesting(uiOpacity > 0.8)
            if videoOpacity > 0.01 && uiOpacity < 0.5 {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture { finishIntro() }
            }
            if let p = dzPlayer {
                ZStack {
                    Color.black.ignoresSafeArea()
                    PlayerView(player: p).ignoresSafeArea()
                }
                .contentShape(Rectangle())
                .onTapGesture { finishDevIntro() }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
        .confirmationDialog("Pod wirklich beenden? Alles im Pod geht verloren (ein Network Volume bleibt erhalten).", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) { Task { await m.terminate() } }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Dev-Volume löschen? Das gespeicherte Programmier-Modell und die Projekte darauf sind dann weg.", isPresented: $confirmDevVol, titleVisibility: .visible) {
            Button("Dev-Volume löschen", role: .destructive) { Task { await m.deleteVolume(dev: true) } }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Volume löschen? Alle gespeicherten Modelle sind dann weg.", isPresented: $confirmVol, titleVisibility: .visible) {
            Button("Volume löschen", role: .destructive) { Task { await m.deleteVolume() } }
            Button("Abbrechen", role: .cancel) {}
        }
        .fullScreenCover(item: $web) { w in
            ZStack(alignment: .topLeading) {
                Color(red: 0.10, green: 0.10, blue: 0.10).ignoresSafeArea()
                ChatWebView(url: w.url, onClose: { web = nil }, onNoBack: { noBack = $0 })
                    .ignoresSafeArea(.container, edges: .all)
                if noBack {
                    Button { web = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundColor(.white.opacity(0.75)).padding(10)
                    }.padding(.top, 36)
                }
            }
        }
        .onAppear {
            if (m.apiKey.isEmpty && m.vastKey.isEmpty) || m.hfToken.isEmpty { showSettings = true }
            m.startLoop()
            Task { await m.licenseGate() }
            startIntro()
            hideKeyboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { hideKeyboard() }
        }
        .onChange(of: scene) { s in
            if s == .active { m.startLoop(); hideKeyboard(); Task { await m.licenseGate() } } else if s == .background { m.stopLoop() }
        }
        .onChange(of: m.phase) { ph in
            if ph == .none { dzSeen = false }
        }
        .onChange(of: m.licenseOK) { ok in
            if !ok { web = nil }
        }
        .onReceive(Timer.publish(every: 600, on: .main, in: .common).autoconnect()) { _ in
            Task { await m.licenseGate() }
        }
    }
}

@main
struct KIStartApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
