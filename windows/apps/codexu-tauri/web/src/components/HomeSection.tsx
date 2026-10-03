import { useId, useState, type ReactNode } from 'react';
import { ChevronDown, ChevronRight } from 'lucide-react';

export function HomeSection({ id, title, children, initialOpen = true }: { id: string; title: string; children: ReactNode; initialOpen?: boolean }) {
  const key = `aigoodbro.home.${id}.expanded`;
  const contentId = useId();
  const [expanded, setExpanded] = useState(() => {
    try { const saved = localStorage.getItem(key); return saved === null ? initialOpen : saved === 'true'; }
    catch { return initialOpen; }
  });
  return <section className="space-y-3" data-home-section={id}>
    <button type="button" className="flex items-center gap-2 text-sm font-semibold text-primary rounded-lg focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4"
      aria-expanded={expanded} aria-controls={contentId} onClick={() => {
        const next = !expanded;
        setExpanded(next);
        try { localStorage.setItem(key, String(next)); } catch { /* Session preference still works. */ }
      }}>
      {expanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />} {title}
    </button>
    <div id={contentId} hidden={!expanded}>{expanded && children}</div>
  </section>;
}
