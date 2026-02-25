import { useState, FormEvent } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { useAuth } from '../auth';
import type { CSSProperties } from 'react';

const pageStyle: CSSProperties = {
  minHeight: '100vh',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  background: '#f5f5f5',
};
const cardStyle: CSSProperties = {
  background: '#fff',
  padding: '2rem',
  borderRadius: 8,
  width: 360,
  boxShadow: '0 2px 8px rgba(0,0,0,0.1)',
};
const headStyle: CSSProperties = { marginTop: 0, fontSize: '1.5rem' };
const errStyle: CSSProperties = { color: 'red', marginBottom: '1rem', fontSize: '0.9rem' };
const fieldStyle: CSSProperties = { marginBottom: '1rem' };
const fieldStyleLast: CSSProperties = { marginBottom: '1.5rem' };
const labelStyle: CSSProperties = { display: 'block', marginBottom: '0.25rem', fontWeight: 500 };
const inputStyle: CSSProperties = {
  width: '100%',
  padding: '0.5rem 0.75rem',
  border: '1px solid #ccc',
  borderRadius: 4,
  fontSize: '1rem',
};
const btnStyle: CSSProperties = {
  width: '100%',
  padding: '0.6rem',
  background: '#1a1a2e',
  color: '#fff',
  border: 'none',
  borderRadius: 4,
  fontSize: '1rem',
  cursor: 'pointer',
};
const footerStyle: CSSProperties = { marginTop: '1rem', textAlign: 'center', fontSize: '0.9rem' };

export default function LoginPage() {
  const { login } = useAuth();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      const tok = localStorage.getItem('token');
      const res = await fetch('/api/v1/auth/login', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(tok ? { Authorization: `Bearer ${tok}` } : {}),
        },
        body: JSON.stringify({ email, password }),
      });
      if (!res.ok) {
        const text = await res.text().catch(() => 'Login failed');
        throw new Error(text);
      }
      const data = await res.json() as Record<string, unknown>;
      const token = (data.token ?? data.access_token ?? data.jwt) as string | undefined;
      if (!token) throw new Error('No token in response');
      login(token);
      navigate('/');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Login failed');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div style={pageStyle}>
      <div style={cardStyle}>
        <h1 style={headStyle}>Sign In</h1>
        {error && <div style={errStyle}>{error}</div>}
        <form onSubmit={handleSubmit}>
          <div style={fieldStyle}>
            <label htmlFor="email" style={labelStyle}>Email</label>
            <input id="email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} required style={inputStyle} />
          </div>
          <div style={fieldStyleLast}>
            <label htmlFor="password" style={labelStyle}>Password</label>
            <input id="password" type="password" value={password} onChange={(e) => setPassword(e.target.value)} required style={inputStyle} />
          </div>
          <button type="submit" disabled={loading} style={btnStyle}>
            {loading ? 'Signing in...' : 'Sign In'}
          </button>
        </form>
        <p style={footerStyle}>
          Don't have an account? <Link to="/register">Register</Link>
        </p>
      </div>
    </div>
  );
}
