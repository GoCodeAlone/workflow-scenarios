import { Outlet, NavLink } from 'react-router-dom';
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
  return (
    <div style={wrapStyle}>
      <nav style={navStyle}>
        <div style={titleStyle}>Ecommerce App</div>
        <NavLink to="/" end style={linkStyle}>Dashboard</NavLink>
        <NavLink to="/orders" style={linkStyle}>Orders</NavLink>
        <NavLink to="/products" style={linkStyle}>Products</NavLink>
        <NavLink to="/healthz" style={linkStyle}>Healthz</NavLink>
        <NavLink to="/init-db" style={linkStyle}>InitDb</NavLink>
        <NavLink to="/payment" style={linkStyle}>Payment</NavLink>
      </nav>
      <main style={mainStyle}>
        <Outlet />
      </main>
    </div>
  );
}
