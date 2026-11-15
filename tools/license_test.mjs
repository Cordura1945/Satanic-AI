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
process.exit(bad ? 1 : 0);
