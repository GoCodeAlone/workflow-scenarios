// Scenario 101 Admin UI — WebAuthn ceremony + bootstrap flow.
// All WebAuthn JSON serialization follows the standard
// navigator.credentials.create().toJSON() / .get().toJSON() shapes that
// go-webauthn's ParseCredentialCreationResponseBody and
// ParseCredentialRequestResponseBody expect.

// ---------------------------------------------------------------------------
// Base64url helpers (RFC 4648 §5)
// ---------------------------------------------------------------------------

function b64urlToBuffer(b64url) {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function bufferToB64url(buf) {
  const bytes = new Uint8Array(buf instanceof ArrayBuffer ? buf : buf.buffer);
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

// ---------------------------------------------------------------------------
// go-webauthn JSON shape helpers
// ---------------------------------------------------------------------------

// Decode go-webauthn CredentialCreationOptions response from the server.
// `options` is a JSON string with top-level `.publicKey`.
function decodeCreationOptions(optionsJSON) {
  const parsed = typeof optionsJSON === 'string' ? JSON.parse(optionsJSON) : optionsJSON;
  const pk = parsed.publicKey;

  pk.challenge = b64urlToBuffer(pk.challenge);
  pk.user.id = b64urlToBuffer(pk.user.id || '');

  if (Array.isArray(pk.excludeCredentials)) {
    pk.excludeCredentials = pk.excludeCredentials.map(c => ({
      ...c,
      id: b64urlToBuffer(c.id),
    }));
  }
  return pk;
}

// Decode go-webauthn CredentialAssertion response from the server.
// `options` is a JSON string with top-level `.publicKey`.
function decodeAssertionOptions(optionsJSON) {
  const parsed = typeof optionsJSON === 'string' ? JSON.parse(optionsJSON) : optionsJSON;
  const pk = parsed.publicKey;

  pk.challenge = b64urlToBuffer(pk.challenge);

  if (Array.isArray(pk.allowCredentials)) {
    pk.allowCredentials = pk.allowCredentials.map(c => ({
      ...c,
      id: b64urlToBuffer(c.id),
    }));
  }
  return pk;
}

// Encode a PublicKeyCredential (create) into the JSON shape that
// go-webauthn's ParseCredentialCreationResponseBody expects.
// Shape: { id, rawId, type, response:{ clientDataJSON, attestationObject, transports? } }
// All binary fields are base64url strings.
function encodeAttestationResponse(cred) {
  return JSON.stringify({
    id: cred.id,
    rawId: bufferToB64url(cred.rawId),
    type: cred.type,
    response: {
      clientDataJSON: bufferToB64url(cred.response.clientDataJSON),
      attestationObject: bufferToB64url(cred.response.attestationObject),
      transports: cred.response.getTransports ? cred.response.getTransports() : [],
    },
    extensions: cred.getClientExtensionResults ? cred.getClientExtensionResults() : {},
  });
}

// Encode a PublicKeyCredential (get) into the JSON shape that
// go-webauthn's ParseCredentialRequestResponseBody expects.
// Shape: { id, rawId, type, response:{ clientDataJSON, authenticatorData, signature, userHandle? } }
function encodeAssertionResponse(cred) {
  const response = {
    clientDataJSON: bufferToB64url(cred.response.clientDataJSON),
    authenticatorData: bufferToB64url(cred.response.authenticatorData),
    signature: bufferToB64url(cred.response.signature),
  };
  if (cred.response.userHandle) {
    response.userHandle = bufferToB64url(cred.response.userHandle);
  }
  return JSON.stringify({
    id: cred.id,
    rawId: bufferToB64url(cred.rawId),
    type: cred.type,
    response,
    extensions: cred.getClientExtensionResults ? cred.getClientExtensionResults() : {},
  });
}

// ---------------------------------------------------------------------------
// Session storage
// ---------------------------------------------------------------------------

function getToken() { return sessionStorage.getItem('s101_token') || ''; }
function setToken(t) { sessionStorage.setItem('s101_token', t); }
function clearToken() { sessionStorage.removeItem('s101_token'); }
function getEmail() { return sessionStorage.getItem('s101_email') || ''; }
function setEmail(e) { sessionStorage.setItem('s101_email', e); }

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

function showMsg(id, text, isErr) {
  const el = document.getElementById(id);
  el.textContent = text;
  el.className = 'msg ' + (isErr ? 'msg-err' : 'msg-ok');
}
function clearMsg(id) {
  const el = document.getElementById(id);
  el.textContent = '';
  el.className = 'msg';
}

function showPanel(name) {
  ['bootstrap', 'authed', 'signin'].forEach(p => {
    document.getElementById('panel-' + p).classList.add('hidden');
  });
  document.getElementById('panel-' + name).classList.remove('hidden');
}

async function api(path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = 'Bearer ' + token;
  const resp = await fetch(path, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  let data = null;
  try { data = await resp.json(); } catch (_) {}
  return { status: resp.status, data };
}

// ---------------------------------------------------------------------------
// Bootstrap flow
// ---------------------------------------------------------------------------

async function init() {
  const badge = document.getElementById('status-badge');
  let bootstrapOpen = false;
  try {
    const r = await fetch('/admin/bootstrap/status');
    const d = await r.json();
    bootstrapOpen = !!d.open;
    badge.textContent = bootstrapOpen ? 'OPEN' : 'CLOSED';
    badge.className = 'badge-' + (bootstrapOpen ? 'open' : 'closed');
  } catch (e) {
    badge.textContent = 'error';
  }

  const token = getToken();
  if (token) {
    const email = getEmail();
    document.getElementById('authed-email').textContent = email;
    showPanel('authed');
    return;
  }

  if (bootstrapOpen) {
    showPanel('bootstrap');
  } else {
    showPanel('signin');
  }
}

document.getElementById('btn-redeem').addEventListener('click', async () => {
  clearMsg('msg-redeem');
  const code = document.getElementById('code').value.trim();
  if (!code) return showMsg('msg-redeem', 'Enter a bootstrap code', true);

  const { status, data } = await api('/admin/bootstrap/redeem', { code });
  if (status !== 200 || !data || !data.token) {
    return showMsg('msg-redeem', (data && data.reason) || 'Redeem failed', true);
  }

  setToken(data.token);
  setEmail('admin@scenario-101.test');
  document.getElementById('authed-email').textContent = 'admin@scenario-101.test';
  showMsg('msg-redeem', 'Redeemed. Session active.', false);
  showPanel('authed');
});

// ---------------------------------------------------------------------------
// Passkey enrolment (register)
// ---------------------------------------------------------------------------

document.getElementById('btn-enrol').addEventListener('click', async () => {
  clearMsg('msg-enrol');
  const token = getToken();
  if (!token) return showMsg('msg-enrol', 'Not authenticated', true);

  // 1. Begin registration
  let beginData;
  try {
    const { status, data } = await api(
      '/admin/credentials/passkey/register/begin', {}, token
    );
    if (status !== 200) {
      return showMsg('msg-enrol', 'Begin failed: ' + status, true);
    }
    beginData = data;
  } catch (e) {
    return showMsg('msg-enrol', 'Begin error: ' + e.message, true);
  }

  // 2. Decode options and call navigator.credentials.create
  let cred;
  try {
    const publicKey = decodeCreationOptions(beginData.options);
    cred = await navigator.credentials.create({ publicKey });
  } catch (e) {
    return showMsg('msg-enrol', 'Authenticator error: ' + e.message, true);
  }

  // 3. Serialize and POST to finish
  const attestation = encodeAttestationResponse(cred);
  try {
    const { status, data } = await api(
      '/admin/credentials/passkey/register/finish',
      { session_data: beginData.session_data, attestation },
      token
    );
    if (status !== 200 || !data || !data.registered) {
      return showMsg('msg-enrol', 'Finish failed: ' + JSON.stringify(data), true);
    }
    showMsg('msg-enrol', 'Passkey enrolled successfully.', false);
  } catch (e) {
    return showMsg('msg-enrol', 'Finish error: ' + e.message, true);
  }
});

// ---------------------------------------------------------------------------
// Logout
// ---------------------------------------------------------------------------

document.getElementById('btn-logout').addEventListener('click', async () => {
  const token = getToken();
  if (token) {
    await api('/admin/logout', {}, token).catch(() => {});
  }
  clearToken();
  setEmail('');
  location.reload();
});

// ---------------------------------------------------------------------------
// Passkey sign-in (login)
// ---------------------------------------------------------------------------

document.getElementById('btn-signin').addEventListener('click', async () => {
  clearMsg('msg-signin');
  const email = document.getElementById('signin-email').value.trim();
  if (!email) return showMsg('msg-signin', 'Enter your email', true);

  // 1. Begin login (user-specific)
  let beginData;
  try {
    const { status, data } = await api('/admin/login/passkey/begin', { email });
    if (status !== 200) {
      return showMsg('msg-signin', 'Begin login failed: ' + status, true);
    }
    beginData = data;
  } catch (e) {
    return showMsg('msg-signin', 'Begin error: ' + e.message, true);
  }

  // 2. Decode and call navigator.credentials.get
  let cred;
  try {
    const publicKey = decodeAssertionOptions(beginData.options);
    cred = await navigator.credentials.get({ publicKey });
  } catch (e) {
    return showMsg('msg-signin', 'Authenticator error: ' + e.message, true);
  }

  // 3. Serialize and POST to finish
  const assertion = encodeAssertionResponse(cred);
  try {
    const { status, data } = await api('/admin/login/passkey/finish', {
      email,
      session_data: beginData.session_data,
      assertion,
    });
    if (status !== 200 || !data || !data.token) {
      return showMsg('msg-signin', 'Login failed: ' + JSON.stringify(data), true);
    }
    setToken(data.token);
    setEmail(email);
    document.getElementById('authed-email').textContent = email;
    showPanel('authed');
  } catch (e) {
    return showMsg('msg-signin', 'Finish error: ' + e.message, true);
  }
});

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------
init();
