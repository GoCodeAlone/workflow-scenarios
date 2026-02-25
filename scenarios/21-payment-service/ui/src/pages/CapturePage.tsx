import { useState, useEffect, FormEvent } from 'react';
import type { CSSProperties } from 'react';
import DataTable from '../components/DataTable';

type Item = Record<string, unknown>;

const headerStyle: CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1.5rem' };
const h1Style: CSSProperties = { margin: 0 };
const newBtnStyle: CSSProperties = { padding: '0.5rem 1rem', background: '#1a1a2e', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' };
const errStyle: CSSProperties = { color: 'red', marginBottom: '1rem' };
const formBoxStyle: CSSProperties = { background: '#f9f9f9', padding: '1.5rem', borderRadius: 8, marginBottom: '1.5rem', border: '1px solid #eee' };
const formHeadStyle: CSSProperties = { marginTop: 0, fontSize: '1.1rem' };
const submitBtnStyle: CSSProperties = { padding: '0.5rem 1.5rem', background: '#1a1a2e', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' };
const loadingStyle: CSSProperties = { color: '#999' };
const detailBoxStyle: CSSProperties = { marginTop: '1.5rem', background: '#f9f9f9', padding: '1.5rem', borderRadius: 8, border: '1px solid #eee' };
const detailHeadStyle: CSSProperties = { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1rem' };
const detailTitleStyle: CSSProperties = { margin: 0, fontSize: '1.1rem' };
const detailBtnsStyle: CSSProperties = { display: 'flex', gap: '0.5rem' };
const deleteBtnStyle: CSSProperties = { padding: '0.4rem 0.8rem', background: '#dc3545', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' };
const closeBtnStyle: CSSProperties = { padding: '0.4rem 0.8rem', background: '#6c757d', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' };
const preStyle: CSSProperties = { margin: 0, fontSize: '0.85rem', overflow: 'auto' };

export default function CapturePage() {
  const [items, setItems] = useState<Item[]>([]);
  const [selected, setSelected] = useState<Item | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [form, setForm] = useState<Record<string, string>>({
  });



  const columns = items.length > 0
    ? Object.keys(items[0]).slice(0, 5).map((k) => ({ key: k as keyof Item, label: k }))
    : [];

  return (
    <div>
      <div style={headerStyle}>
        <h1 style={h1Style}>Capture</h1>
      </div>
      {error && <div style={errStyle}>{error}</div>}
      {loading ? (
        <div style={loadingStyle}>Loading...</div>
      ) : (
        <DataTable columns={columns} rows={items} onSelect={(row) => setSelected(row)} />
      )}
      {selected && (
        <div style={detailBoxStyle}>
          <div style={detailHeadStyle}>
            <h2 style={detailTitleStyle}>Detail</h2>
            <div style={detailBtnsStyle}>
              <button onClick={() => setSelected(null)} style={closeBtnStyle}>Close</button>
            </div>
          </div>
          <pre style={preStyle}>{JSON.stringify(selected, null, 2)}</pre>
        </div>
      )}
    </div>
  );
}
