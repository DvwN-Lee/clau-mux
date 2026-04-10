import { Card } from './components/Card';

export function App() {
  return (
    <main style={{ padding: '20px', fontFamily: 'system-ui, sans-serif' }}>
      <h1>clmux Browser Inspect Test</h1>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '16px' }}>
        <Card title="First" variant="default" />
        <Card title="Second" variant="highlighted" />
        <Card title="Third" variant="default" />
      </div>
    </main>
  );
}
