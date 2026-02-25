import type { CSSProperties } from 'react';

interface Column<T> {
  key: keyof T;
  label: string;
}

interface DataTableProps<T extends Record<string, unknown>> {
  columns: Column<T>[];
  rows: T[];
  onSelect?: (row: T) => void;
}

const tableStyle: CSSProperties = { width: '100%', borderCollapse: 'collapse' };
const thStyle: CSSProperties = {
  textAlign: 'left',
  padding: '0.5rem 1rem',
  background: '#f5f5f5',
  borderBottom: '2px solid #ddd',
  fontWeight: 600,
};
const tdStyle: CSSProperties = {
  padding: '0.5rem 1rem',
  borderBottom: '1px solid #eee',
};
const emptyStyle: CSSProperties = {
  padding: '0.5rem 1rem',
  borderBottom: '1px solid #eee',
  textAlign: 'center',
  color: '#999',
};

export default function DataTable<T extends Record<string, unknown>>({
  columns,
  rows,
  onSelect,
}: DataTableProps<T>) {
  return (
    <table style={tableStyle}>
      <thead>
        <tr>
          {columns.map((col) => (
            <th key={String(col.key)} style={thStyle}>{col.label}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.map((row, i) => (
          <tr
            key={i}
            onClick={() => onSelect?.(row)}
            style={onSelect ? { cursor: 'pointer' } : undefined}
          >
            {columns.map((col) => (
              <td key={String(col.key)} style={tdStyle}>
                {String(row[col.key] ?? '')}
              </td>
            ))}
          </tr>
        ))}
        {rows.length === 0 && (
          <tr>
            <td colSpan={columns.length} style={emptyStyle}>
              No data
            </td>
          </tr>
        )}
      </tbody>
    </table>
  );
}
