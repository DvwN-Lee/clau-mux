interface CardProps {
  title: string;
  variant?: 'default' | 'highlighted';
}

export function Card({ title, variant = 'default' }: CardProps) {
  const bg = variant === 'highlighted' ? 'rgb(66, 133, 244)' : 'rgb(240, 240, 240)';
  const color = variant === 'highlighted' ? 'white' : 'black';
  return (
    <div
      className={`card card--${variant}`}
      style={{
        padding: '12px',
        background: bg,
        color,
        borderRadius: '4px',
        fontSize: '14px',
      }}
    >
      <h3 style={{ margin: 0 }}>{title}</h3>
      <p>Click me with clmux inspect mode.</p>
    </div>
  );
}
