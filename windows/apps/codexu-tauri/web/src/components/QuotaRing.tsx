interface QuotaRingProps {
  label: string;
  remaining: number | null;
  description: string;
  stale?: boolean;
  secondary?: boolean;
}

/** A display of a returned window. Null is unknown, never an empty quota. */
export function QuotaRing({ label, remaining, description, stale = false, secondary = false }: QuotaRingProps) {
  const value = remaining === null ? null : Math.min(100, Math.max(0, remaining));
  return <div className={`quota-ring ${stale ? 'is-stale' : ''} ${secondary ? 'is-secondary' : ''}`}
    role="img" aria-label={description} title={description} data-known={value !== null}>
    <div className="quota-ring-graphic">
      <svg viewBox="0 0 48 48" aria-hidden="true">
        <circle className="quota-ring-track" cx="24" cy="24" r="20" />
        {value !== null && value > 0 && <circle className={`quota-ring-value ${value <= 20 ? 'is-low' : ''}`} cx="24" cy="24" r="20"
          pathLength="100" strokeDasharray={`${value} 100`} transform="rotate(-90 24 24)" />}
      </svg>
      <span className="quota-ring-number">{value === null ? '—' : `${Number(value.toFixed(1))}%`}</span>
    </div>
    <span className="quota-ring-name">{label}</span>
    <span className="sr-only">{description}</span>
  </div>;
}
