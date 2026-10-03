import { useEffect, useState } from 'react';
import { useI18n } from '../i18n/I18nProvider';
import { resetCountdown, type ResetKind } from '../utils/resetTime';

export function ResetCountdown({ deadline, kind = 'account' }: { deadline: number | null; kind?: ResetKind }) {
  const { language } = useI18n();
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const update = () => setNow(Date.now());
    update();
    const timer = window.setInterval(update, 1000);
    document.addEventListener('visibilitychange', update);
    window.addEventListener('focus', update);
    return () => {
      window.clearInterval(timer);
      document.removeEventListener('visibilitychange', update);
      window.removeEventListener('focus', update);
    };
  }, [deadline]);
  return <span className="tabular-nums" data-testid={`${kind}-reset-countdown`} aria-live="off">
    {resetCountdown(deadline, now, kind, language === 'zh-Hans')}
  </span>;
}
