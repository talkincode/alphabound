/** Operator consent page of the built-in authorization server (self-contained HTML, no external loads). */

export const CONSENT_PATH = "/oauth/consent";

/** The page must never be framed, cached, or leak its URL (it embeds a request id). */
export const PAGE_HEADERS = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Frame-Options": "DENY",
  // No form-action: browsers apply it to the post-submit redirect, which must reach the client.
  "Content-Security-Policy":
    "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'",
};

const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

const CSS = `
body{font:16px/1.5 system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1rem}
h1{font-size:1.3rem}
code{word-break:break-all;font-size:.85rem}
dl{margin:1rem 0;padding:.75rem 1rem;border:1px solid #8884;border-radius:.5rem}
dt{font-size:.8rem;opacity:.7}
dd{margin:0}
input{display:block;width:100%;box-sizing:border-box;margin:.5rem 0 1rem;padding:.5rem;font:inherit}
button{font:inherit;padding:.5rem 1.2rem;margin-right:.5rem;cursor:pointer}
.err{color:#c62828;font-weight:600}
`;

function page(title, body) {
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${esc(title)}</title><style>${CSS}</style></head>
<body>${body}</body></html>`;
}

/** Where the browser lands after approval, in words the operator can check against the client. */
function describeRedirect(uri) {
  const u = new URL(uri);
  if (u.protocol === "https:") return u.host;
  if (u.protocol === "http:") return `${u.host} (an app on the device running this browser)`;
  return `${u.protocol}//${u.host} (a desktop app link)`;
}

export function renderConsent({ requestId, clientName, redirectUri, error = "" }) {
  return page(
    "Authorize MCP client",
    `<h1>Authorize MCP client</h1>
<p><strong>${esc(clientName)}</strong> (self-reported name) asks to read AlphaBound analytics — portfolio state,
decisions, orders, events — and to forward pre-signed intel envelopes. It cannot trade, flatten, or read secrets.</p>
<dl><dt>After you approve, your browser is sent to</dt>
<dd><strong>${esc(describeRedirect(redirectUri))}</strong><br><code>${esc(redirectUri)}</code></dd></dl>
<p>Approve only a client you just connected yourself. Enter the AlphaBound API token to confirm.</p>
<form method="post" action="${CONSENT_PATH}">
<input type="hidden" name="request_id" value="${esc(requestId)}">
<label>API token<input type="password" name="token" autocomplete="current-password" maxlength="256" required autofocus></label>
${error ? `<p class="err">${esc(error)}</p>` : ""}
<button type="submit" name="decision" value="approve">Approve</button>
<button type="submit" name="decision" value="deny" formnovalidate>Deny</button>
</form>`,
  );
}

export function renderMessage(title, text) {
  return page(title, `<h1>${esc(title)}</h1><p>${esc(text)}</p>`);
}
