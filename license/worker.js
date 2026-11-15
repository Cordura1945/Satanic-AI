// Satanic AI – Lizenz-Server (Cloudflare Worker)
// Deploy: Cloudflare Dashboard → Workers → New Worker → Code hier einfügen → Deploy
// Danach: Worker-URL notieren (z.B. https://satanic-license.yourname.workers.dev)

const KEYS = {
  // Beispiel-Key – ersetzen durch echte Keys
  "satanic-0001": {
    email: "beispiel@mail.com",
    fingerprint: "",
    created_at: "2026-02-15T10:00:00Z",
    revoked: false
  }
};

// Offline-Toleranz: App akzeptiert letzte gültige Antwort für 7 Tage
const OFFLINE_DAYS = 7;

export default {
  async fetch(request) {
    // CORS
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, GET",
          "Access-Control-Allow-Headers": "Content-Type"
        }
      });
    }

    const cors = { "Access-Control-Allow-Origin": "*" };

    if (request.method === "GET" && request.url.includes("/health")) {
      return new Response(JSON.stringify({ ok: true, keys: Object.keys(KEYS).length }), {
        headers: { "Content-Type": "application/json", ...cors }
      });
    }

    if (request.method !== "POST") {
      return new Response(JSON.stringify({ valid: false, reason: "method_not_allowed" }), {
        status: 405, headers: { "Content-Type": "application/json", ...cors }
      });
    }

    let body;
    try {
      body = await request.json();
    } catch (e) {
      return new Response(JSON.stringify({ valid: false, reason: "bad_json" }), {
        status: 400, headers: { "Content-Type": "application/json", ...cors }
      });
    }

    const { key, fingerprint } = body;

    if (!key || !fingerprint) {
      return new Response(JSON.stringify({ valid: false, reason: "missing_key_or_fingerprint" }), {
        status: 400, headers: { "Content-Type": "application/json", ...cors }
      });
    }

    const entry = KEYS[key];

    if (!entry) {
      return new Response(JSON.stringify({ valid: false, reason: "key_not_found" }), {
        status: 403, headers: { "Content-Type": "application/json", ...cors }
      });
    }

    if (entry.revoked) {
      return new Response(JSON.stringify({ valid: false, reason: "revoked" }), {
        status: 403, headers: { "Content-Type": "application/json", ...cors }
      });
    }

    // Fingerprint-Prüfung:
    // - Wenn noch kein Fingerprint gespeichert ist → jetzt speichern (erster Start)
    // - Wenn Fingerprint gespeichert ist → muss stimmen
    if (entry.fingerprint === "") {
      // Erster Start: Fingerprint jetzt binden
      entry.fingerprint = fingerprint;
      return new Response(JSON.stringify({
        valid: true,
        email: entry.email,
        bound: true,
        message: "Fingerprint wurde jetzt an diesen Key gebunden."
      }), { headers: { "Content-Type": "application/json", ...cors } });
    }

    if (entry.fingerprint !== fingerprint) {
      return new Response(JSON.stringify({ valid: false, reason: "fingerprint_mismatch" }), {
        status: 403, headers: { "Content-Type": "application/json", ...cors }
      });
    }

    return new Response(JSON.stringify({
      valid: true,
      email: entry.email,
      created_at: entry.created_at
    }), { headers: { "Content-Type": "application/json", ...cors } });
  }
};
