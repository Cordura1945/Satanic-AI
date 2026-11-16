// Prueft den Lizenz-Server (license/worker.js) mit einem nachgebauten Speicher. Aufruf: node tools/license_test.mjs
import worker from "../license/worker.js";
class KV {
  constructor() { this.m = new Map(); }
  async get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v) { this.m.set(k, v); }
  async delete(k) { this.m.delete(k); }
  async list({ prefix }) { return { keys: [...this.m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }; }
}
const env = { LIC: new KV(), ADMIN_PW: "test-passwort-123" };
let bad = 0;
const ok = (c, t) => { console.log((c ? "OK     " : "FEHLER ") + t); if (!c) bad++; };
const call = async (path, body, pw, e = env, method = "POST") => {
  const r = await worker.fetch(new Request("https://x.test" + path, { method, headers: { "Content-Type": "application/json", ...(pw ? { "X-Admin": pw } : {}) }, body: method === "POST" ? JSON.stringify(body) : undefined }), e);
  const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch (x) {}
  return { s: r.status, j, t };
};
let r = await call("/api", { action: "list" }, "falsch");
ok(r.s === 401, "falsches Admin-Passwort wird abgelehnt");
r = await call("/api", { action: "list" }, "x", { LIC: new KV() });
ok(r.s === 503, "ohne gesetztes Admin-Passwort ist die Verwaltung gesperrt");
r = await call("/api", { action: "create", note: "Kaeufer 1" }, env.ADMIN_PW);
const key = r.j && r.j.key;
ok(r.s === 200 && /^SATANIC-[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$/.test(key || ""), "Key erzeugen: " + key);
r = await call("/verify", { key: "SATANIC-GIBT-ESNI-CHTX-XXXX", device: "geraet-aaaaaaaa" });
ok(r.s === 403 && r.j.reason === "key_unbekannt", "unbekannter Key wird abgelehnt");
r = await call("/verify", { key: key.toLowerCase() + "  ", device: "geraet-aaaaaaaa" });
ok(r.s === 200 && r.j.valid === true, "erster Start bindet den Key an Geraet A (Gross/Klein und Leerzeichen egal)");
r = await call("/verify", { key, device: "geraet-aaaaaaaa" });
ok(r.s === 200 && r.j.valid === true, "Geraet A bleibt gueltig");
r = await call("/verify", { key, device: "geraet-bbbbbbbb" });
ok(r.s === 403 && r.j.reason === "anderes_geraet", "Geraet B wird mit demselben Key abgelehnt");
ok(!JSON.stringify([...env.LIC.m.values()]).includes("geraet-aaaaaaaa"), "Geraetekennung wird nur als Pruefsumme gespeichert");
r = await call("/api", { action: "reset", key }, env.ADMIN_PW);
r = await call("/verify", { key, device: "geraet-bbbbbbbb" });
ok(r.s === 200 && r.j.valid, "nach Zuruecksetzen bindet sich Geraet B");
r = await call("/api", { action: "revoke", key }, env.ADMIN_PW);
r = await call("/verify", { key, device: "geraet-bbbbbbbb" });
ok(r.s === 403 && r.j.reason === "gesperrt", "gesperrter Key wird abgelehnt");
r = await call("/api", { action: "revoke", key, revoked: false }, env.ADMIN_PW);
r = await call("/verify", { key, device: "geraet-bbbbbbbb" });
ok(r.s === 200 && r.j.valid, "entsperrter Key gilt wieder");
r = await call("/api", { action: "list" }, env.ADMIN_PW);
ok(r.s === 200 && r.j.keys.length === 1 && r.j.keys[0].note === "Kaeufer 1" && r.j.keys[0].device === true, "Liste zeigt Key, Notiz und Bindung");
r = await call("/verify", { key }, null);
ok(r.s === 400, "Anfrage ohne Geraetekennung wird abgelehnt");
r = await call("/api", { action: "delete", key }, env.ADMIN_PW);
r = await call("/verify", { key, device: "geraet-bbbbbbbb" });
ok(r.s === 403, "geloeschter Key gilt nicht mehr");
r = await call("/admin", null, null, env, "GET");
ok(r.s === 200 && r.t.includes("SATANIC LIZENZEN") && !r.t.includes("test-passwort"), "Verwaltungsseite wird ausgeliefert");
r = await call("/health", null, null, env, "GET");
ok(r.s === 200 && r.j.ok, "Lebenszeichen /health");
const lag = { LIC: new KV(), ADMIN_PW: env.ADMIN_PW };
r = await call("/api", { action: "create", note: "neu" }, lag.ADMIN_PW, lag);
const k2 = r.j.key;
lag.LIC.list = async () => ({ keys: [], list_complete: true });
r = await call("/api", { action: "list", extra: [k2, "SATANIC-GIBT-ESNI-CHTX-XXXX"] }, lag.ADMIN_PW, lag);
ok(r.s === 200 && r.j.keys.length === 1 && r.j.keys[0].key === k2, "frisch erzeugter Key erscheint auch, wenn die Liste des Speichers nachhaengt");
// Test-Lizenzen mit Laufzeit
const tv = { LIC: new KV(), ADMIN_PW: env.ADMIN_PW };
r = await call("/api", { action: "create", note: "Tester", hours: 24 }, tv.ADMIN_PW, tv); const tk = r.j.key;
r = await call("/api", { action: "list" }, tv.ADMIN_PW, tv);
ok(r.j.keys[0].hours === 24 && r.j.keys[0].start === "", "Test-Key: Laufzeit beginnt nicht beim Erzeugen");
r = await call("/verify", { key: tk, device: "tester-geraet-1" }, null, tv);
ok(r.s === 200 && r.j.valid && r.j.test === true && Math.abs(r.j.until - Date.now() - 24 * 3600000) < 60000, "Test-Key: erster Start gueltig, Ende in 24 Stunden");
const first = r.j.until;
r = await call("/verify", { key: tk, device: "tester-geraet-1" }, null, tv);
ok(r.j.valid && r.j.until === first, "Test-Key: das Ende verschiebt sich bei weiteren Pruefungen nicht");
const shift = async (h) => { const e = JSON.parse(await tv.LIC.get("key:" + tk)); e.start = new Date(Date.now() - h * 3600000).toISOString(); await tv.LIC.put("key:" + tk, JSON.stringify(e)); };
await shift(23.9); r = await call("/verify", { key: tk, device: "tester-geraet-1" }, null, tv); ok(r.s === 200 && r.j.valid, "Test-Key: kurz vor Ablauf noch gueltig");
await shift(24.1); r = await call("/verify", { key: tk, device: "tester-geraet-1" }, null, tv); ok(r.s === 403 && r.j.reason === "abgelaufen", "Test-Key: nach 24 Stunden abgelaufen");
await call("/api", { action: "reset", key: tk }, tv.ADMIN_PW, tv);
r = await call("/verify", { key: tk, device: "tester-geraet-2" }, null, tv); ok(r.s === 403 && r.j.reason === "abgelaufen", "Test-Key: Geraet zuruecksetzen verlaengert nicht, kein neues Geraet wird gebunden");
r = await call("/api", { action: "list" }, tv.ADMIN_PW, tv); ok(r.j.keys[0].device === false, "abgelaufener Key bindet kein neues Geraet");
await call("/api", { action: "restart", key: tk }, tv.ADMIN_PW, tv);
r = await call("/verify", { key: tk, device: "tester-geraet-2" }, null, tv); ok(r.s === 200 && r.j.valid && r.j.until > Date.now() + 23 * 3600000, "Laufzeit neu starten gibt wieder 24 Stunden");
r = await call("/api", { action: "create", note: "voll" }, tv.ADMIN_PW, tv);
r = await call("/verify", { key: r.j.key, device: "kaeufer-geraet-1" }, null, tv); ok(r.j.valid && r.j.test === undefined && r.j.until === undefined, "Voll-Lizenz hat keine Laufzeit");
// Setup-Abruf fuer den Pod
const sv = { LIC: new KV(), ADMIN_PW: env.ADMIN_PW };
await sv.LIC.put("setup:main", "#!/bin/bash\necho hallo\n");
const getSetup = async (name, lic) => { const q = await worker.fetch(new Request("https://x.test/setup/" + name, { headers: lic ? { "X-License": lic } : {} }), sv); return { s: q.status, t: await q.text() }; };
r = await call("/api", { action: "create", note: "voll" }, sv.ADMIN_PW, sv); const sk = r.j.key;
r = await getSetup("main", ""); ok(r.s === 400, "Setup-Abruf ohne Lizenz-Key wird abgelehnt");
r = await getSetup("main", "SATANIC-GIBT-ESNI-CHTX-XXXX"); ok(r.s === 403 && !r.t.includes("hallo"), "Setup-Abruf mit unbekanntem Key wird abgelehnt");
r = await getSetup("main", sk.toLowerCase()); ok(r.s === 200 && r.t.startsWith("#!/bin/bash") && r.t.includes("hallo"), "Setup-Abruf mit gueltigem Key liefert das Skript");
r = await call("/api", { action: "list" }, sv.ADMIN_PW, sv); ok(r.j.keys.length === 1 && r.j.keys[0].device === false, "Setup-Abruf bindet kein Geraet, Setup-Eintrag taucht nicht in der Key-Liste auf");
r = await getSetup("gibtsnicht", sk); ok(r.s === 404, "unbekanntes Setup: 404");
r = await getSetup("a%2F..%2Fkey:x", sk); ok(r.s === 400, "Setup-Name mit unerlaubten Zeichen wird abgelehnt");
await call("/api", { action: "revoke", key: sk }, sv.ADMIN_PW, sv);
r = await getSetup("main", sk); ok(r.s === 403, "Setup-Abruf mit gesperrtem Key wird abgelehnt");
r = await call("/api", { action: "create", note: "Tester", hours: 24 }, sv.ADMIN_PW, sv); const stk = r.j.key;
r = await call("/verify", { key: stk, device: "tester-geraet-9" }, null, sv);
r = await getSetup("main", stk); ok(r.s === 200, "Setup-Abruf mit laufender Test-Lizenz geht");
{ const e = JSON.parse(await sv.LIC.get("key:" + stk)); e.start = new Date(Date.now() - 25 * 3600000).toISOString(); await sv.LIC.put("key:" + stk, JSON.stringify(e)); }
r = await getSetup("main", stk); ok(r.s === 403, "Setup-Abruf mit abgelaufener Test-Lizenz wird abgelehnt");
process.exit(bad ? 1 : 0);
