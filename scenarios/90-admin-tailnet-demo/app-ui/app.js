const tokenKey = 'scenario90.app.token';
const state = {
  token: localStorage.getItem(tokenKey) || '',
};

const els = {
  email: document.querySelector('#email'),
  password: document.querySelector('#password'),
  login: document.querySelector('#login'),
  register: document.querySelector('#register'),
  logout: document.querySelector('#logout'),
  status: document.querySelector('#status'),
  access: document.querySelector('#access'),
  orders: document.querySelector('#orders'),
  update: document.querySelector('#update'),
};

function setStatus(message) {
  els.status.textContent = message;
}

function authHeaders(extra = {}) {
  return state.token ? { ...extra, Authorization: `Bearer ${state.token}` } : extra;
}

async function request(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: authHeaders({ accept: 'application/json', ...(options.headers || {}) }),
  });
  const body = await res.json().catch(() => ({}));
  return { status: res.status, body };
}

async function submitAuth(path) {
  const payload = {
    email: els.email.value,
    password: els.password.value,
    name: els.email.value.split('@')[0] || 'Scenario user',
  };
  const { status, body } = await request(path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const token = body.token || body.access_token || '';
  if (!token) {
    setStatus(`Auth failed (${status})`);
    return;
  }
  state.token = token;
  localStorage.setItem(tokenKey, token);
  setStatus(`Signed in as ${body.user?.email || payload.email}`);
  await refresh();
}

async function refresh() {
  if (!state.token) {
    els.access.textContent = 'Sign in to inspect app scopes.';
    els.orders.textContent = 'Orders are protected by frontend:orders:read.';
    return;
  }
  const access = await request('/api/app/access');
  els.access.textContent = JSON.stringify(access.body, null, 2);
  const orders = await request('/api/app/orders');
  els.orders.textContent = JSON.stringify({ status: orders.status, ...orders.body }, null, 2);
}

els.login.addEventListener('click', () => submitAuth('/api/app/auth/login'));
els.register.addEventListener('click', () => submitAuth('/api/app/auth/register'));
els.logout.addEventListener('click', () => {
  state.token = '';
  localStorage.removeItem(tokenKey);
  setStatus('Signed out');
  refresh();
});
els.update.addEventListener('click', async () => {
  const result = await request('/api/app/orders/update', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ order_id: 'ORD-1002', status: 'priority-review' }),
  });
  els.orders.textContent = JSON.stringify({ status: result.status, ...result.body }, null, 2);
});

refresh();
