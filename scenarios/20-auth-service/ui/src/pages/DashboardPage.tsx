import type { CSSProperties } from 'react';

const headStyle: CSSProperties = { marginTop: 0 };
const cardGridStyle: CSSProperties = {
  display: 'flex',
  gap: '1rem',
  flexWrap: 'wrap',
  marginTop: '1.5rem',
};
const cardStyle: CSSProperties = {
  display: 'block',
  padding: '1rem 1.5rem',
  border: '1px solid #ddd',
  borderRadius: 8,
  textDecoration: 'none',
  color: 'inherit',
  background: '#fafafa',
};
const cardTitleStyle: CSSProperties = { fontWeight: 700, fontSize: '1.1rem' };

export default function DashboardPage() {
  return (
    <div>
      <h1 style={headStyle}>Auth Service</h1>
      <p>Welcome to the dashboard. Use the navigation to explore the API resources.</p>
      <div style={cardGridStyle}>
        <a href="/healthz" style={cardStyle}>
          <div style={cardTitleStyle}>Healthz</div>
        </a>
        <a href="/init-db" style={cardStyle}>
          <div style={cardTitleStyle}>InitDb</div>
        </a>
      </div>
    </div>
  );
}
