const API_BASE = '';

async function apiCall(method: string, path: string, body?: unknown): Promise<unknown> {
  const token = localStorage.getItem('token');
  const res = await fetch(API_BASE + path, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) {
    localStorage.removeItem('token');
    window.location.href = '/login';
    throw new Error('Unauthorized');
  }
  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText);
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const ct = res.headers.get('content-type') ?? '';
  if (ct.includes('application/json')) {
    return res.json();
  }
  return res.text();
}

// Generated API functions

export const postApiV1AuthLogin = (data: any) =>
  apiCall('POST', '/api/v1/auth/login', data);

export const getApiV1AuthProfile = () =>
  apiCall('GET', '/api/v1/auth/profile');

export const postApiV1AuthRegister = (data: any) =>
  apiCall('POST', '/api/v1/auth/register', data);

export const postApiV1AuthUsers = (data: any) =>
  apiCall('POST', '/api/v1/auth/users', data);

export const getHealthz = () =>
  apiCall('GET', '/healthz');

export const postInternalInitDb = (data: any) =>
  apiCall('POST', '/internal/init-db', data);

