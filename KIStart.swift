import SwiftUI
import SafariServices
import Security
import AVFoundation
import WebKit

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
            throw RPError(text: "Ungueltige Antwort (HTTP \(code))")
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

    static func deployMutation(gpu: String, image: String, disk: Int, hf: String, autoStop: Int, setupB64: String, volumeId: String? = nil, dc: String? = nil, idleMin: Int = 0) -> String {
        let cmd = "bash -c \"mkdir -p /workspace && echo $SETUP_B64 | base64 -d > /workspace/setup_all.sh && cd /workspace && bash setup_all.sh 2>&1 | tee /workspace/setup.log; sleep infinity\""
        let env = "[{key:\(q("HF_TOKEN")),value:\(q(hf))},{key:\(q("AUTO_STOP_H")),value:\(q(String(autoStop)))},{key:\(q("IDLE_STOP_MIN")),value:\(q(String(idleMin)))},{key:\(q("SETUP_B64")),value:\(q(setupB64))}]"
        var vol = ""
        if let v = volumeId, !v.isEmpty { vol = "networkVolumeId:\(q(v)),"; if let d = dc, !d.isEmpty { vol += "dataCenterId:\(q(d))," } }
        return "mutation{podFindAndDeployOnDemand(input:{\(vol)cloudType:ALL,gpuCount:1,volumeInGb:0,containerDiskInGb:\(disk),minVcpuCount:2,minMemoryInGb:15,gpuTypeId:\(q(gpu)),name:\"ki-chat\",imageName:\(q(image)),dockerArgs:\(q(cmd)),ports:\"8000/http\",env:\(env)}){id costPerHr machineId}}"
    }
}

// MARK: - Zustand
enum Phase { case none, boot, setup, loading, ready }

@MainActor
final class Model: ObservableObject {
    @Published var apiKey: String { didSet { Keychain.set(apiKey, for: "apiKey") } }
    @Published var hfToken: String { didSet { Keychain.set(hfToken, for: "hfToken") } }
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
    @Published var maxPrice: Double { didSet { UserDefaults.standard.set(maxPrice, forKey: "maxPrice") } }

    @Published var balance: Double? = nil
    @Published var spend: Double = 0
    @Published var phase: Phase = .none
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
        let gl = "NVIDIA A40\nNVIDIA RTX A6000\nNVIDIA L40S\nNVIDIA L40\nNVIDIA RTX 6000 Ada Generation"
        if !u.bool(forKey: "gpusV3") { u.set(gl, forKey: "gpus"); u.set(true, forKey: "gpusV3") }
        gpus = u.string(forKey: "gpus") ?? gl
        maxPrice = u.object(forKey: "maxPrice") as? Double ?? 0.60
        mode = u.string(forKey: "mode") ?? "demand"
        volGB = u.object(forKey: "volGB") as? Int ?? 60
        dc = u.string(forKey: "dc") ?? "EU-RO-1"
        image = u.string(forKey: "image") ?? "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"
        disk = u.object(forKey: "disk") as? Int ?? 100
        autoStop = u.object(forKey: "autoStop") as? Int ?? 8
        idleStop = u.object(forKey: "idleStop") as? Int ?? 30
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
        guard !apiKey.isEmpty else {
            message = "Unten im Bereich Einstellungen den RunPod-API-Key eintragen."
            return
        }
        do {
            let (d, _) = try await RunPod(key: apiKey).gql("query{myself{clientBalance currentSpendPerHr networkVolumes{id name size dataCenterId} pods{id name desiredStatus costPerHr runtime{uptimeInSeconds}}}}")
            guard let me = d["myself"] as? [String: Any] else { return }
            balance = (me["clientBalance"] as? NSNumber)?.doubleValue
            spend = (me["currentSpendPerHr"] as? NSNumber)?.doubleValue ?? 0
            let vols = me["networkVolumes"] as? [[String: Any]] ?? []
            if let v = vols.first(where: { ($0["name"] as? String) == "ki-chat-vol" }) {
                volId = v["id"] as? String
                let sz = (v["size"] as? NSNumber)?.intValue ?? 0
                volInfo = "\(sz) GB · \(v["dataCenterId"] as? String ?? "?") · ca. $\(String(format: "%.2f", Double(sz) * 0.07))/Monat"
            } else { volId = nil; volInfo = "" }
            let pods = me["pods"] as? [[String: Any]] ?? []
            guard let pod = pods.first(where: { ($0["name"] as? String) == "ki-chat" && ($0["desiredStatus"] as? String) == "RUNNING" }),
                  let id = pod["id"] as? String else {
                podId = nil; phase = .none; info = ""; step = ""; log = []; chatURL = nil; pct = 0; shown = 0; eta = ""; upMin = 0
                return
            }
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
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            message = "RunPod-Fehler: \(error.localizedDescription)"
        }
    }

    func start() async {
        guard !busy else { return }
        guard !apiKey.isEmpty, !hfToken.isEmpty else {
            message = "API-Key und Hugging-Face-Token eintragen."
            return
        }
        guard let url = Bundle.main.url(forResource: "setup_all", withExtension: "sh"),
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
        if mode == "volume" {
            message = "Network Volume wird vorbereitet…"
            do {
                let rp = RunPod(key: apiKey)
                let (d0, _) = try await rp.gql("query{myself{networkVolumes{id name size dataCenterId}}}")
                let vs = (d0["myself"] as? [String: Any])?["networkVolumes"] as? [[String: Any]] ?? []
                if let v = vs.first(where: { ($0["name"] as? String) == "ki-chat-vol" }), let id = v["id"] as? String {
                    useVol = id; useDC = v["dataCenterId"] as? String
                } else {
                    let (code, obj) = try await rp.rest("POST", "/v2/network-volumes", ["name": "ki-chat-vol", "dataCenter": dc, "size": volGB])
                    if let id = obj["id"] as? String {
                        useVol = id; useDC = (obj["dataCenter"] as? String) ?? dc
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
        let list = gpus.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for g in list {
            message = "Versuche \(g)…"
            do {
                let m = RunPod.deployMutation(gpu: g, image: image, disk: disk, hf: hfToken, autoStop: autoStop, setupB64: b64, volumeId: useVol, dc: useDC, idleMin: idleStop)
                let (d, err) = try await RunPod(key: apiKey).gql(m)
                if let p = d["podFindAndDeployOnDemand"] as? [String: Any], let id = p["id"] as? String {
                    let c = (p["costPerHr"] as? NSNumber)?.doubleValue ?? 0
                    if maxPrice > 0 && c > maxPrice {
                        _ = try? await RunPod(key: apiKey).gql("mutation{podTerminate(input:{podId:\(RunPod.q(id))})}")
                        errs.append("\(g): $\(String(format: "%.2f", c))/h > Limit, Pod wieder beendet")
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
        message = "Keine GPU frei oder Fehler:\n" + errs.joined(separator: "\n")
    }

    func deleteVolume() async {
        guard let id = volId else { return }
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
            _ = try await RunPod(key: apiKey).gql("mutation{podTerminate(input:{podId:\(RunPod.q(id))})}")
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
            decisionHandler(a.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let h = r.response as? HTTPURLResponse,
               (h.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().contains("attachment") {
                decisionHandler(.download)
            } else {
                decisionHandler(r.canShowMIMEType ? .allow : .download)
            }
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
    static let gold = Color(red: 0.89, green: 0.69, blue: 0.29)
    static let red = Color(red: 0.90, green: 0.28, blue: 0.22)
    static let card = Color(red: 0.11, green: 0.05, blue: 0.07)
    static let bgTop = Color(red: 0.03, green: 0.02, blue: 0.05)
    static let bgBottom = Color(red: 0.16, green: 0.03, blue: 0.04)
}

struct Card<Content: View>: View {
    var selected = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.58)))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Theme.gold : Theme.gold.opacity(0.25), lineWidth: selected ? 2 : 1))
    }
}

struct Field: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.gold.opacity(0.3), lineWidth: 1))
    }
}

struct ProgressBar: View {
    let value: Double
    var eta: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(LinearGradient(colors: [Theme.red, Theme.gold], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(min(max(value, 0), 100) / 100))
                }
            }.frame(height: 10)
            .animation(.easeInOut(duration: 0.6), value: value)
            Text("\(Int(value)) %" + (eta.isEmpty ? "" : " · \(eta)")).font(.footnote.bold()).foregroundColor(Theme.gold)
        }
    }
}

struct GoldButton: View {
    let title: String
    var danger = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).foregroundColor(danger ? .white : .black)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(danger ? AnyShapeStyle(Theme.red) : AnyShapeStyle(LinearGradient(colors: [Theme.gold, Color(red: 0.72, green: 0.48, blue: 0.16)], startPoint: .top, endPoint: .bottom))))
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
    @State private var showSettings = false
    @State private var noBack = false
    @State private var player: AVPlayer? = nil
    @State private var videoOpacity = 1.0
    @State private var uiOpacity = 0.0
    @State private var introStarted = false

    func startIntro() {
        guard !introStarted else { return }
        introStarted = true
        guard let url = Bundle.main.url(forResource: "splash", withExtension: "mp4") else {
            videoOpacity = 0; uiOpacity = 1; return
        }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
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

    func modeCard(_ id: String, _ name: String, _ text: String) -> some View {
        Button { m.mode = id } label: {
            Card(selected: m.mode == id) {
                HStack {
                    Image(systemName: m.mode == id ? "largecircle.fill.circle" : "circle").foregroundColor(Theme.gold)
                    Text(name).font(.headline).foregroundColor(.white)
                    Spacer()
                }
                Text(text).font(.footnote).foregroundColor(.white.opacity(0.9)).multilineTextAlignment(.leading)
            }
        }.buttonStyle(.plain)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { g in
                Image("Background").resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
            }.ignoresSafeArea()
            if let p = player {
                PlayerView(player: p).ignoresSafeArea().opacity(videoOpacity).allowsHitTesting(false)
            }
            ScrollView {
                VStack(spacing: 16) {
                    Color.clear.frame(height: 4)
                    Card {
                        Text("RUNPOD-GUTHABEN").font(.caption.bold()).foregroundColor(Theme.gold)
                        HStack(alignment: .firstTextBaseline) {
                            Text(m.balance.map { String(format: "$%.2f", $0) } ?? "–").font(.system(size: 36, weight: .bold)).foregroundColor(.white)
                            Spacer()
                            Text(String(format: "Verbrauch: $%.2f/h", m.spend)).font(.footnote).foregroundColor(.white.opacity(0.85))
                        }
                        if let b = m.balance, b < 2 { Text("Guthaben niedrig, bitte aufladen.").font(.footnote).foregroundColor(Theme.red) }
                        Link(destination: URL(string: "https://console.runpod.io/user/billing")!) {
                            Label("Guthaben aufladen", systemImage: "plus.circle.fill").foregroundColor(Theme.gold)
                        }
                    }

                    if m.phase == .none {
                        Text("STARTART WÄHLEN").font(.caption.bold()).foregroundColor(Theme.gold).frame(maxWidth: .infinity, alignment: .leading)
                        modeCard("demand", "On Demand",
                                 "Alles wird bei jedem Start komplett neu heruntergeladen (ca. 10–25 Min Wartezeit, ca. 37 GB). Kein Dauerpreis, du zahlst nur die GPU-Zeit. Die Wartezeit kostet ca. $0.10–0.30 pro Start.")
                        modeCard("volume", "Network Volume",
                                 "Modelle bleiben gespeichert, spätere Starts dauern nur wenige Minuten. Kostet dauerhaft ca. $\(volMonth) pro Monat (\(m.volGB) GB, ca. $0.07/GB), auch wenn kein Pod läuft. Der erste Start lädt alles einmal. GPUs nur im Rechenzentrum des Volumes (\(m.dc)).")
                        if m.mode == "volume" {
                            Card {
                                if m.volId != nil {
                                    Text("Vorhandenes Volume: \(m.volInfo)").font(.footnote).foregroundColor(.white.opacity(0.8))
                                    Button("Volume löschen", role: .destructive) { confirmVol = true }.font(.footnote)
                                } else {
                                    Stepper("Größe: \(m.volGB) GB (ca. $\(volMonth)/Monat)", value: $m.volGB, in: 50...300, step: 10)
                                        .foregroundColor(.white).font(.footnote)
                                }
                            }
                        }
                        GoldButton(title: m.busy ? "Starte…" : "Starten") { Task { await m.start() } }.disabled(m.busy)
                    } else {
                        Card {
                            HStack {
                                Text(title).font(.title3.bold()).foregroundColor(m.phase == .ready ? .green : .white)
                                Spacer()
                                Text(m.info).font(.footnote).foregroundColor(.white.opacity(0.85))
                            }
                            ProgressBar(value: m.shown, eta: m.eta)
                            if !m.step.isEmpty { Text(m.step).font(.footnote).foregroundColor(.white.opacity(0.9)) }
                            if !m.log.isEmpty {
                                Text(m.log.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.8))
                            }
                        }
                        if let u = m.chatURL, m.phase == .loading || m.phase == .ready {
                            GoldButton(title: "Chat öffnen") { web = WebLink(url: u) }
                        }
                        GoldButton(title: "Beenden (Terminate)", danger: true) { confirmStop = true }
                    }
                    if !m.message.isEmpty { Text(m.message).font(.footnote).foregroundColor(.white.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading) }

                    DisclosureGroup(isExpanded: $showSettings) {
                        VStack(alignment: .leading, spacing: 12) {
                            DisclosureGroup("API-Keys erstellen") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("RunPod: Konto anlegen, Guthaben aufladen, dann im Bereich Settings oder Credentials einen API-Key erstellen (Rechte: Lesen und Schreiben). Der Key beginnt mit rpa_.")
                                    Link(destination: URL(string: "https://console.runpod.io/user/settings")!) {
                                        Label("RunPod öffnen", systemImage: "arrow.up.right.square").foregroundColor(Theme.gold)
                                    }
                                    Text("Hugging Face: Konto anlegen, dann unter Settings → Access Tokens ein Token mit Leserechten (Read) erstellen. Es beginnt mit hf_. Damit lädt der Pod die Modelle.")
                                    Link(destination: URL(string: "https://huggingface.co/settings/tokens")!) {
                                        Label("Hugging Face öffnen", systemImage: "arrow.up.right.square").foregroundColor(Theme.gold)
                                    }
                                    Text("Beide Keys nie weitergeben oder im Chat posten. Sie liegen nur im Schlüsselbund dieses iPhones.")
                                        .foregroundColor(.white.opacity(0.7))
                                }.padding(.top, 6)
                            }.tint(Theme.gold)
                            SecureField("RunPod API-Key", text: $m.apiKey).modifier(Field())
                            SecureField("Hugging-Face-Token", text: $m.hfToken).modifier(Field())
                            Stepper("Max. Preis: $\(String(format: "%.2f", m.maxPrice))/h", value: $m.maxPrice, in: 0...3, step: 0.05)
                            Stepper("Auto-Beenden: \(m.autoStop == 0 ? "aus" : "\(m.autoStop) h")", value: $m.autoStop, in: 0...48)
                            Stepper("Leerlauf-Abschaltung: \(m.idleStop == 0 ? "aus" : "\(m.idleStop) Min")", value: $m.idleStop, in: 0...240, step: 5)
                            Stepper("Disk: \(m.disk) GB", value: $m.disk, in: 60...300, step: 10)
                            TextField("Rechenzentrum (nur Volume)", text: $m.dc).modifier(Field()).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            TextField("Docker-Image", text: $m.image).modifier(Field()).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }.padding(.top, 8).foregroundColor(.white).font(.footnote)
                    } label: {
                        Text("EINSTELLUNGEN").font(.caption.bold()).foregroundColor(Theme.gold)
                    }
                    .tint(Theme.gold)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.58)))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.gold.opacity(0.25), lineWidth: 1))
                    .padding(.top, 8)
                }
                .padding(.horizontal, 16).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
            .onTapGesture { hideKeyboard() }
            .opacity(uiOpacity)
            .offset(y: (1 - uiOpacity) * 24)
            .allowsHitTesting(uiOpacity > 0.8)
            if videoOpacity > 0.01 && uiOpacity < 0.5 {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea().onTapGesture { finishIntro() }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.gold)
        .confirmationDialog("Pod wirklich beenden? Alles im Pod geht verloren (ein Network Volume bleibt erhalten).", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Beenden", role: .destructive) { Task { await m.terminate() } }
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
            if m.apiKey.isEmpty || m.hfToken.isEmpty { showSettings = true }
            m.startLoop()
            startIntro()
            hideKeyboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { hideKeyboard() }
        }
        .onChange(of: scene) { s in
            if s == .active { m.startLoop(); hideKeyboard() } else if s == .background { m.stopLoop() }
        }
    }
}

@main
struct KIStartApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
