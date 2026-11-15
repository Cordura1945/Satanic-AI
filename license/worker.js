// Satanic AI – Lizenz-Server (Cloudflare Worker)
// Speicher: KV-Bindung LIC (Keys, Geraetebindung, Sperren). Admin-Passwort: Secret ADMIN_PW.
// Wird ueber GitHub Actions uebertragen (.github/workflows/lizenz-server.yml), nicht von Hand.

const HEAD = { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store" };
const J = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: HEAD });
const now = () => new Date().toISOString();
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function sha(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

function newKey() {
  const abc = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const b = crypto.getRandomValues(new Uint8Array(16));
  let s = "";
  for (let i = 0; i < 16; i++) { s += abc[b[i] % 32]; if (i % 4 === 3 && i < 15) s += "-"; }
  return "SATANIC-" + s;
}

const cleanKey = (k) => String(k || "").trim().toUpperCase();

async function verify(request, env) {
  let b;
  try { b = await request.json(); } catch (e) { return J({ valid: false, reason: "ungueltige_anfrage" }, 400); }
  const key = cleanKey(b.key), device = String(b.device || "").trim();
  if (!key || key.length > 64 || device.length < 8 || device.length > 128) return J({ valid: false, reason: "ungueltige_anfrage" }, 400);
  const raw = await env.LIC.get("key:" + key);
  if (!raw) return J({ valid: false, reason: "key_unbekannt" }, 403);
  const e = JSON.parse(raw);
  if (e.revoked) return J({ valid: false, reason: "gesperrt" }, 403);
  // Test-Lizenz: die Laufzeit beginnt beim ersten Start und wird hier auf dem Server gemessen
  if (e.hours && e.start && Date.now() > Date.parse(e.start) + e.hours * 3600000) return J({ valid: false, reason: "abgelaufen" }, 403);
  const dev = await sha(device);
  let changed = false;
  if (!e.device) { e.device = dev; e.bound = now(); changed = true; }
  else if (e.device !== dev) return J({ valid: false, reason: "anderes_geraet" }, 403);
  if ((e.last || "").slice(0, 10) !== now().slice(0, 10)) { e.last = now(); changed = true; }
  if (e.hours && !e.start) { e.start = now(); changed = true; }
  if (changed) await env.LIC.put("key:" + key, JSON.stringify(e));
  if (!e.hours) return J({ valid: true });
  return J({ valid: true, test: true, until: Date.parse(e.start) + e.hours * 3600000 });
}

async function admin(request, env) {
  if (!env.ADMIN_PW) return J({ error: "Admin-Passwort ist auf dem Server noch nicht gesetzt." }, 503);
  const [want, got] = await Promise.all([sha("pw:" + env.ADMIN_PW), sha("pw:" + (request.headers.get("X-Admin") || ""))]);
  if (want !== got) { await wait(700); return J({ error: "Admin-Passwort falsch." }, 401); }
  let b;
  try { b = await request.json(); } catch (e) { return J({ error: "ungueltige Anfrage" }, 400); }
  const key = cleanKey(b.key);
  if (b.action === "list") {
    // Die Liste des Speichers haengt nach Aenderungen kurz nach. Deshalb nennt die Verwaltung
    // frisch erzeugte Keys selbst (extra); gelesen wird jeder Key einzeln.
    const names = new Set(); let cursor;
    do {
      const page = await env.LIC.list({ prefix: "key:", cursor });
      for (const k of page.keys) names.add(k.name);
      cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor);
    for (const x of (Array.isArray(b.extra) ? b.extra.slice(0, 50) : [])) {
      const k = cleanKey(x);
      if (k && k.length <= 64) names.add("key:" + k);
    }
    const out = [];
    for (const name of names) {
      const raw = await env.LIC.get(name);
      if (!raw) continue;
      const e = JSON.parse(raw);
      out.push({ key: name.slice(4), note: e.note || "", created: e.created || "", bound: e.bound || "", last: e.last || "", device: !!e.device, revoked: !!e.revoked, hours: e.hours || 0, start: e.start || "" });
    }
    out.sort((x, y) => (x.created < y.created ? 1 : -1));
    return J({ keys: out });
  }
  if (b.action === "create") {
    const k = newKey();
    await env.LIC.put("key:" + k, JSON.stringify({ note: String(b.note || "").slice(0, 120), created: now(), device: "", revoked: false, hours: Math.max(0, Math.min(parseInt(b.hours) || 0, 8760)) }));
    return J({ key: k });
  }
  if (!key) return J({ error: "key fehlt" }, 400);
  const raw = await env.LIC.get("key:" + key);
  if (!raw) return J({ error: "Key nicht gefunden" }, 404);
  const e = JSON.parse(raw);
  if (b.action === "revoke") e.revoked = b.revoked !== false;
  else if (b.action === "reset") { e.device = ""; e.bound = ""; }
  else if (b.action === "restart") e.start = "";
  else if (b.action === "delete") { await env.LIC.delete("key:" + key); return J({ ok: true }); }
  else return J({ error: "unbekannte Aktion" }, 400);
  await env.LIC.put("key:" + key, JSON.stringify(e));
  return J({ ok: true });
}

const PAGE = `<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Satanic Lizenzen</title><style>
body{margin:0;background:#0a0a0d;color:#ececf2;font:14px ui-monospace,Menlo,monospace;padding:16px;max-width:760px;margin:auto}
h1{color:#e8625a;font-size:20px;margin:6px 0 14px}h2{color:#3fb950;font-size:12px;letter-spacing:.08em;margin:18px 0 6px}
input,select,button{font:inherit;border-radius:8px;border:1px solid #2e2e3a;background:#14141b;color:#ececf2;padding:10px}
input,select{width:100%;box-sizing:border-box;margin-bottom:8px;font-size:16px}button{cursor:pointer;color:#3fb950;border-color:#3fb950}
button.r{color:#e8625a;border-color:#e8625a}button.g{color:#a2a2ae;border-color:#3a3a46}
.k{border:1px solid #2e2e3a;border-radius:10px;padding:10px;margin-top:8px;background:#14141b}.k b{color:#e3b341;word-break:break-all}
.k small{display:block;color:#a2a2ae;margin:4px 0 8px;line-height:1.5}.k button{padding:6px 10px;margin:0 6px 6px 0;font-size:13px}
#msg{color:#e3b341;min-height:20px;margin:8px 0;white-space:pre-wrap}.off b{color:#a2a2ae;text-decoration:line-through}
</style></head><body><h1>&gt; SATANIC LIZENZEN</h1>
<div id="login"><input id="pw" type="password" placeholder="Admin-Passwort" autocomplete="off"><button id="go">Anmelden</button></div>
<div id="app" style="display:none"><h2>&gt; NEUER KEY</h2><input id="note" placeholder="Notiz, z. B. Kaeufer 12" maxlength="120"><select id="typ"><option value="0">Voll-Lizenz, unbegrenzt</option><option value="24">Test, 24 Stunden</option><option value="72">Test, 3 Tage</option></select><button id="mk">Key erzeugen</button>
<h2>&gt; KEYS</h2><div id="list"></div></div><div id="msg"></div>
<script>
var pw=sessionStorage.getItem('pw')||'';var mine=[];try{mine=JSON.parse(sessionStorage.getItem('mine')||'[]')}catch(e){}var $=function(i){return document.getElementById(i)};
function say(t){$('msg').textContent=t}
function api(o){return fetch('/api',{method:'POST',headers:{'Content-Type':'application/json','X-Admin':pw},body:JSON.stringify(o)}).then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||('Fehler '+r.status));return j})})}
function d(t){var x=t?new Date(t):null;return x&&!isNaN(x)?x.toLocaleString('de-DE',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}):'-'}
function btn(t,c,f){var b=document.createElement('button');b.textContent=t;if(c)b.className=c;b.onclick=f;return b}
function act(o,t){api(o).then(function(){say(t);load()}).catch(function(e){say(e.message)})}
function load(){api({action:'list',extra:mine}).then(function(j){$('login').style.display='none';$('app').style.display='block';var L=$('list');L.textContent='';
if(!j.keys.length){L.textContent='Noch keine Keys.'}
j.keys.forEach(function(k){var x=document.createElement('div');x.className='k'+(k.revoked?' off':'');var b=document.createElement('b');b.textContent=k.key;x.appendChild(b);
var bis=k.hours&&k.start?Date.parse(k.start)+k.hours*3600000:0;var art=k.hours?'TEST '+k.hours+' h, '+(bis?(bis<Date.now()?'ABGELAUFEN seit ':'laeuft bis ')+d(bis):'Laufzeit beginnt beim ersten Start'):'Voll-Lizenz';
var s=document.createElement('small');s.textContent=(k.note||'ohne Notiz')+' | '+art+' | erstellt '+d(k.created)+' | '+(k.revoked?'GESPERRT':k.device?'gebunden seit '+d(k.bound):'noch nicht benutzt')+' | zuletzt geprueft '+d(k.last);x.appendChild(s);
x.appendChild(btn('Kopieren','g',function(){navigator.clipboard.writeText(k.key).then(function(){say('Kopiert: '+k.key)})}));
x.appendChild(btn(k.revoked?'Entsperren':'Sperren',k.revoked?'':'r',function(){act({action:'revoke',key:k.key,revoked:!k.revoked},k.revoked?'Entsperrt.':'Gesperrt.')}));
if(k.device)x.appendChild(btn('Geraet zuruecksetzen','g',function(){act({action:'reset',key:k.key},'Geraetebindung geloescht.')}));
if(bis)x.appendChild(btn('Laufzeit neu starten','g',function(){act({action:'restart',key:k.key},'Die Laufzeit beginnt beim naechsten Start neu.')}));
x.appendChild(btn('Loeschen','r',function(){if(confirm('Key '+k.key+' endgueltig loeschen?'))act({action:'delete',key:k.key},'Geloescht.')}));
L.appendChild(x)})}).catch(function(e){sessionStorage.removeItem('pw');$('login').style.display='block';$('app').style.display='none';say(e.message)})}
$('go').onclick=function(){pw=$('pw').value;sessionStorage.setItem('pw',pw);say('');load()};
$('mk').onclick=function(){api({action:'create',note:$('note').value,hours:parseInt($('typ').value)||0}).then(function(j){$('note').value='';mine.push(j.key);try{sessionStorage.setItem('mine',JSON.stringify(mine))}catch(e){}say('Neuer Key: '+j.key);load()}).catch(function(e){say(e.message)})};
if(pw)load();
</script></body></html>`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, GET", "Access-Control-Allow-Headers": "Content-Type" } });
    }
    if (request.method === "GET" && url.pathname === "/health") return J({ ok: true });
    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/admin")) {
      return new Response(PAGE, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Frame-Options": "DENY" } });
    }
    if (request.method === "POST" && url.pathname === "/verify") return verify(request, env);
    if (request.method === "POST" && url.pathname === "/api") return admin(request, env);
    return J({ error: "nicht gefunden" }, 404);
  },
};
