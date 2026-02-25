import type { CSSProperties } from 'react';

interface FormFieldProps {
  name: string;
  label: string;
  type?: string;
  value: string;
  onChange: (name: string, value: string) => void;
  required?: boolean;
  options?: string[];
}

const wrapStyle: CSSProperties = { marginBottom: '1rem' };
const labelStyle: CSSProperties = {
  display: 'block',
  marginBottom: '0.25rem',
  fontWeight: 500,
  fontSize: '0.9rem',
};
const inputStyle: CSSProperties = {
  width: '100%',
  padding: '0.5rem 0.75rem',
  border: '1px solid #ccc',
  borderRadius: 4,
  fontSize: '1rem',
};
const reqStyle: CSSProperties = { color: 'red' };

export default function FormField({
  name,
  label,
  type = 'text',
  value,
  onChange,
  required = false,
  options = [],
}: FormFieldProps) {
  return (
    <div style={wrapStyle}>
      <label htmlFor={name} style={labelStyle}>
        {label}{required && <span style={reqStyle}> *</span>}
      </label>
      {type === 'select' ? (
        <select
          id={name}
          name={name}
          value={value}
          required={required}
          onChange={(e) => onChange(name, e.target.value)}
          style={inputStyle}
        >
          <option value="">Select...</option>
          {options.map((o) => (
            <option key={o} value={o}>{o}</option>
          ))}
        </select>
      ) : (
        <input
          id={name}
          name={name}
          type={type}
          value={value}
          required={required}
          onChange={(e) => onChange(name, e.target.value)}
          style={inputStyle}
        />
      )}
    </div>
  );
}
