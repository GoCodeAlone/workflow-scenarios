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

export const getApiV1Orders = () =>
  apiCall('GET', '/api/v1/orders');

export const postApiV1Orders = (data: any) =>
  apiCall('POST', '/api/v1/orders', data);

export const getApiV1OrdersById = (id: string) =>
  apiCall('GET', `/api/v1/orders/${id}`);

export const getApiV1Products = () =>
  apiCall('GET', '/api/v1/products');

export const postApiV1Products = (data: any) =>
  apiCall('POST', '/api/v1/products', data);

export const getApiV1ProductsById = (id: string) =>
  apiCall('GET', `/api/v1/products/${id}`);

export const putApiV1ProductsById = (id: string, data: any) =>
  apiCall('PUT', `/api/v1/products/${id}`, data);

export const getHealthz = () =>
  apiCall('GET', '/healthz');

export const postInternalInitDb = (data: any) =>
  apiCall('POST', '/internal/init-db', data);

export const postWebhooksPayment = (data: any) =>
  apiCall('POST', '/webhooks/payment', data);

