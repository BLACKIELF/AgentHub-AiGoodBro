import { Dashboard } from './windows/Dashboard';
import { Settings } from './windows/Settings';
import { FloatingQuotaBubble } from './windows/FloatingQuotaBubble';
import { TokenMonitorCompact } from './windows/TokenMonitorCompact';
import { getCurrentWindow } from '@tauri-apps/api/window';
import React from 'react';
import { useI18n } from './i18n/I18nProvider';

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

class AppErrorBoundary extends React.Component<
  { children?: React.ReactNode },
  ErrorBoundaryState
> {
  state: ErrorBoundaryState = { hasError: false, error: null };

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    console.error('[AppErrorBoundary] Runtime error:', error, info);
  }

  render() {
    if (this.state.hasError) {
      return <ErrorFallback error={this.state.error} />;
    }

    return this.props.children as React.ReactElement;
  }
}

function getWindowLabel() {
  try {
    return getCurrentWindow().label;
  } catch (error) {
    console.error('[App] Failed to read current window label:', error);
    return 'main';
  }
}

function App() {
  const label = getWindowLabel();
  if (label === 'token-monitor-floating-bubble') return <FloatingQuotaBubble />;
  if (label === 'token-monitor-bubble-editor') return <FloatingQuotaBubble editor />;
  const surface=({'token-monitor-popover':'popover','token-monitor-edge-peek':'edge_peek','token-monitor-edge-rail':'edge_rail','token-monitor-edge-card':'edge_card'} as const)[label as 'token-monitor-popover'];
  return surface ? <TokenMonitorCompact surface={surface}/> : label === 'settings' ? <Settings /> : <Dashboard />;
}

function ErrorFallback({ error }: { error: Error | null }) {
  const { t } = useI18n();
  return (
    <div className="h-screen p-4 bg-transparent text-primary box-border">
      <div className="mx-auto max-w-2xl glass-panel p-4">
        <h2 className="text-lg font-semibold mb-2">{t('common.applicationError')}</h2>
        <pre className="text-sm whitespace-pre-wrap break-words bg-surface-inset rounded-lg border border-theme p-3">
          {(error && error.message) || t('common.unknownError')}
        </pre>
        <button
          onClick={() => window.location.reload()}
          className="mt-3 px-3 py-2 rounded-full glass-button-solid text-sm"
        >
          {t('common.reload')}
        </button>
      </div>
    </div>
  );
}

export default function AppWithBoundary() {
  return (
    <AppErrorBoundary>
      <App />
    </AppErrorBoundary>
  );
}
