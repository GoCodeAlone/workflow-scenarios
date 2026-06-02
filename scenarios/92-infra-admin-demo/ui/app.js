/* Scenario 92 — Infra Admin GitOps Demo SPA */
'use strict';

const BASE = '';  // same-origin
let token = '';

// ── helpers ─────────────────────────────────────────────────────────────────

async function apiFetch(path, opts = {}) {
  const headers = { 'Content-Type': 'application/json', ...(opts.headers || {}) };
  if (token) headers['Authorization'] = 'Bearer ' + token;
  const res = await fetch(BASE + path, { ...opts, headers });
  let body;
  try { body = await res.json(); } catch { body = {}; }
  return { status: res.status, body };
}

function show(el, cls, msg) {
  el.className = 'status ' + cls;
  el.textContent = msg;
  el.style.display = '';
}
function hide(el) { el.style.display = 'none'; }

// ── Auth ─────────────────────────────────────────────────────────────────────

document.getElementById('btn-register').addEventListener('click', async () => {
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;
  const msg = document.getElementById('auth-msg');
  const { status, body } = await apiFetch('/api/admin/auth/register', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  if (status === 200 || status === 201) {
    show(msg, 'ok', 'Registered. Now sign in.');
  } else {
    show(msg, 'err', 'Register failed: ' + (body.error || status));
  }
});

document.getElementById('btn-login').addEventListener('click', async () => {
  const email = document.getElementById('login-email').value.trim();
  const password = document.getElementById('login-password').value;
  const msg = document.getElementById('auth-msg');
  const { status, body } = await apiFetch('/api/admin/auth/login', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  if (status === 200 && body.token) {
    token = body.token;
    document.getElementById('auth-status').textContent = 'authenticated: ' + email;
    document.getElementById('auth-status').className = 'badge badge-green';
    show(msg, 'ok', 'Signed in as ' + email);
  } else {
    show(msg, 'err', 'Login failed: ' + (body.error || status));
  }
});

document.getElementById('btn-logout').addEventListener('click', () => {
  token = '';
  document.getElementById('auth-status').textContent = 'not authenticated';
  document.getElementById('auth-status').className = 'badge badge-gray';
  hide(document.getElementById('auth-msg'));
});

// ── Catalog ──────────────────────────────────────────────────────────────────

document.getElementById('btn-load-catalog').addEventListener('click', async () => {
  const msg = document.getElementById('catalog-msg');
  const badge = document.getElementById('catalog-loaded');
  const regionSel = document.getElementById('resource-region');
  const typeSel = document.getElementById('resource-type');

  const { status, body } = await apiFetch('/api/infra/providers/stub/catalog');
  if (status !== 200) {
    show(msg, 'err', 'Catalog failed: ' + status);
    return;
  }

  // Populate region dropdown
  regionSel.innerHTML = '<option value="">— select region —</option>';
  (body.regions || []).forEach(r => {
    const opt = document.createElement('option');
    opt.value = r.name;
    opt.textContent = r.display_name || r.name;
    regionSel.appendChild(opt);
  });

  // Populate type dropdown
  typeSel.innerHTML = '<option value="">— select type —</option>';
  (body.types || []).forEach(t => {
    const opt = document.createElement('option');
    opt.value = t;
    opt.textContent = t;
    typeSel.appendChild(opt);
  });

  badge.textContent = 'loaded';
  badge.className = 'badge badge-green';
  show(msg, 'ok', 'Catalog loaded: ' + (body.regions || []).length + ' regions, ' + (body.types || []).length + ' types');
});

// ── Plan ─────────────────────────────────────────────────────────────────────

document.getElementById('btn-plan').addEventListener('click', async () => {
  const msg = document.getElementById('plan-msg');
  const resultDiv = document.getElementById('plan-result');
  const resourceName = document.getElementById('resource-name').value.trim() || 'demo-database';
  const resourceType = document.getElementById('resource-type').value || 'stub.database';
  const resourceRegion = document.getElementById('resource-region').value || 'stub-east';

  const { status, body } = await apiFetch('/api/infra/plan', {
    method: 'POST',
    body: JSON.stringify({
      provider: 'stub',
      specs: [{ name: resourceName, type: resourceType, region: resourceRegion }],
    }),
  });

  if (status !== 200) {
    show(msg, 'err', 'Plan failed: ' + status);
    hide(resultDiv);
    return;
  }

  const actions = (body.plan && body.plan.actions) || [];
  document.getElementById('plan-actions-summary').textContent =
    actions.length + ' action(s): ' + actions.map(a => a.action).join(', ');
  document.getElementById('plan-actions-summary').className = 'status ok';
  document.getElementById('plan-hash').textContent = body.desired_hash || '';
  document.getElementById('plan-actions').textContent = JSON.stringify(actions, null, 2);
  resultDiv.style.display = '';
  hide(msg);
});

// ── Commit ───────────────────────────────────────────────────────────────────

document.getElementById('btn-commit').addEventListener('click', async () => {
  const msg = document.getElementById('commit-msg');
  const resultDiv = document.getElementById('commit-result');
  const branch = document.getElementById('commit-branch').value.trim() || 'feat/gitops-demo';
  const message = document.getElementById('commit-message').value.trim() || 'chore(infra): update desired state';
  const resourceName = document.getElementById('resource-name').value.trim() || 'demo-database';
  const resourceType = document.getElementById('resource-type').value || 'stub.database';
  const resourceRegion = document.getElementById('resource-region').value || 'stub-east';

  show(msg, 'info', 'Committing…');

  const { status, body } = await apiFetch('/api/infra/commit', {
    method: 'POST',
    body: JSON.stringify({
      specs: [{ name: resourceName, type: resourceType, region: resourceRegion }],
      branch,
      message,
    }),
  });

  if (status !== 200) {
    show(msg, 'err', 'Commit failed: ' + status + ' ' + JSON.stringify(body));
    hide(resultDiv);
    return;
  }

  const branchDisplay = document.getElementById('commit-branch-display');
  branchDisplay.textContent = '✓ Committed to branch: ' + (body.branch || branch);
  branchDisplay.className = 'status ok';
  resultDiv.style.display = '';
  hide(msg);
});

// ── Resources ────────────────────────────────────────────────────────────────

document.getElementById('btn-refresh-resources').addEventListener('click', async () => {
  const msg = document.getElementById('resources-msg');
  const tbody = document.getElementById('resources-body');

  const { status, body } = await apiFetch('/api/infra/resources?provider=stub');
  if (status !== 200) {
    show(msg, 'err', 'Resources failed: ' + status);
    return;
  }

  const resources = body.resources || [];
  tbody.innerHTML = '';
  if (resources.length === 0) {
    show(msg, 'info', 'No resources in state store.');
    return;
  }
  resources.forEach(r => {
    const tr = document.createElement('tr');
    tr.innerHTML =
      '<td>' + (r.name || r.resource_id || '—') + '</td>' +
      '<td>' + (r.resource_type || '—') + '</td>' +
      '<td>' + (r.provider || 'stub') + '</td>' +
      '<td><span class="badge badge-blue">' + (r.status || 'unknown') + '</span></td>';
    tbody.appendChild(tr);
  });
  hide(msg);
});

// ── Drift ────────────────────────────────────────────────────────────────────

document.getElementById('btn-drift').addEventListener('click', async () => {
  const msg = document.getElementById('drift-msg');
  const resultDiv = document.getElementById('drift-result');

  const { status, body } = await apiFetch('/api/infra/drift?provider=stub');
  if (status !== 200) {
    show(msg, 'err', 'Drift check failed: ' + status);
    hide(resultDiv);
    return;
  }

  const driftStatus = document.getElementById('drift-status');
  const driftCount = (body.drifts || []).length;
  if (!body.supported) {
    driftStatus.textContent = 'Drift detection not supported by this provider';
    driftStatus.className = 'status info';
  } else if (driftCount === 0) {
    driftStatus.textContent = '✓ No drift detected (supported: true, drifted: 0)';
    driftStatus.className = 'status ok';
  } else {
    driftStatus.textContent = '⚠ ' + driftCount + ' resource(s) drifted';
    driftStatus.className = 'status err';
  }
  resultDiv.style.display = '';
  hide(msg);
});

// ── Secrets ──────────────────────────────────────────────────────────────────

document.getElementById('btn-secrets-list').addEventListener('click', async () => {
  const msg = document.getElementById('secrets-msg');
  const listEl = document.getElementById('secrets-list');

  const { status, body } = await apiFetch('/api/infra/secrets');
  if (status !== 200) {
    show(msg, 'err', 'Secrets list failed: ' + status);
    return;
  }

  const secrets = body.secrets || [];
  if (secrets.length === 0) {
    listEl.textContent = 'No secrets declared.';
  } else {
    listEl.innerHTML = secrets.map(s => {
      const name = (typeof s === 'object') ? (s.name || JSON.stringify(s)) : s;
      const backend = (typeof s === 'object') ? (s.backend || 'env') : 'env';
      return '<div style="padding:3px 0"><span class="badge badge-blue">' + name + '</span> <span style="color:#718096">' + backend + '</span></div>';
    }).join('');
  }
  hide(msg);
});

document.getElementById('btn-secrets-declare').addEventListener('click', async () => {
  const name = document.getElementById('secret-name').value.trim();
  const backend = document.getElementById('secret-backend').value;
  const msg = document.getElementById('secrets-msg');

  if (!name) {
    show(msg, 'err', 'Secret name is required');
    return;
  }

  const { status, body } = await apiFetch('/api/infra/secrets', {
    method: 'POST',
    body: JSON.stringify({ name, backend }),
  });

  if (status === 200) {
    show(msg, 'ok', 'Declared: ' + (body.name || name) + ' (' + backend + ')');
  } else {
    show(msg, 'err', 'Declare failed: ' + status + ' ' + JSON.stringify(body));
  }
});

// ── AuthZ / CSRF checks ──────────────────────────────────────────────────────

document.getElementById('btn-test-authz').addEventListener('click', async () => {
  const resultsEl = document.getElementById('authz-results');
  resultsEl.style.display = '';
  resultsEl.textContent = 'Running…';

  const results = [];

  // 1. Unauthenticated POST /api/infra/plan → must 401
  {
    const res = await fetch(BASE + '/api/infra/plan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: 'stub', specs: [] }),
    });
    const pass = res.status === 401;
    results.push({ label: 'Unauthenticated POST /api/infra/plan → 401', pass, got: res.status });
  }

  // 2. Unauthenticated POST /api/infra/commit → must 401
  {
    const res = await fetch(BASE + '/api/infra/commit', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ specs: [] }),
    });
    const pass = res.status === 401;
    results.push({ label: 'Unauthenticated POST /api/infra/commit → 401', pass, got: res.status });
  }

  // 3. Unauthenticated POST /api/infra/secrets → must 401
  {
    const res = await fetch(BASE + '/api/infra/secrets', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'test', backend: 'env' }),
    });
    const pass = res.status === 401;
    results.push({ label: 'Unauthenticated POST /api/infra/secrets → 401', pass, got: res.status });
  }

  // 4. Authenticated GET /api/infra/drift → 200 (operator)
  if (token) {
    const { status } = await apiFetch('/api/infra/drift?provider=stub');
    const pass = status === 200;
    results.push({ label: 'Authenticated GET /api/infra/drift → 200', pass, got: status });
  } else {
    results.push({ label: 'Authenticated drift check (skip — not logged in)', pass: null, got: 'skipped' });
  }

  // 5. CSRF: cross-origin POST without Bearer → rejected (simulated via no-auth)
  {
    const res = await fetch(BASE + '/api/infra/apply', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: 'stub', specs: [] }),
    });
    const pass = res.status === 401;
    results.push({ label: 'CSRF: no-bearer POST /api/infra/apply → 401', pass, got: res.status });
  }

  resultsEl.textContent = results.map(r => {
    const icon = r.pass === null ? '⊘' : r.pass ? '✓' : '✗';
    return icon + ' ' + r.label + ' (got: ' + r.got + ')';
  }).join('\n');
});
