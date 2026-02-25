import { Outlet, NavLink } from 'react-router-dom';
import { useAuth } from '../auth';
import type { CSSProperties } from 'react';

const navStyle: CSSProperties = {
  width: 220,
  minHeight: '100vh',
  background: '#1a1a2e',
  color: '#eee',
  padding: '1rem',
  display: 'flex',
  flexDirection: 'column',
  gap: '0.5rem',
};

const linkStyle: CSSProperties = {
  color: '#ccc',
  textDecoration: 'none',
  padding: '0.4rem 0.6rem',
  borderRadius: 4,
};

const mainStyle: CSSProperties = {
  flex: 1,
  padding: '2rem',
};

const titleStyle: CSSProperties = {
  fontSize: '1.1rem',
  fontWeight: 700,
  marginBottom: '1rem',
  color: '#fff',
};

const wrapStyle: CSSProperties = {
  display: 'flex',
};

export default function Layout() {
  const { logout } = useAuth();
  return (
    <div style={wrapStyle}>
      <nav style={navStyle}>
        <div style={titleStyle}>Auth Service</div>
        <NavLink to="/" end style={linkStyle}>Dashboard</NavLink>
        <NavLink to="/healthz" style={linkStyle}>Healthz</NavLink>
        <NavLink to="/init-db" style={linkStyle}>InitDb</NavLink>
        <div style={logoutWrapStyle}>
          <button onClick={logout} style={logoutBtnStyle}>Logout</button>
        </div>
      </nav>
      <main style={mainStyle}>
        <Outlet />
      </main>
    </div>
  );
}

const logoutWrapStyle: CSSProperties = { marginTop: 'auto' };
const logoutBtnStyle: CSSProperties = {
  background: 'none',
  border: '1px solid #555',
  color: '#ccc',
  padding: '0.4rem 0.8rem',
  borderRadius: 4,
  cursor: 'pointer',
};
