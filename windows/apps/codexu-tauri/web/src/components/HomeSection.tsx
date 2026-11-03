import { useId, useState, type ReactNode } from 'react';
import { ChevronDown, ChevronRight } from 'lucide-react';

export function useHomeSectionState(id: string, initialOpen = true, forceOpen = false) {
  const key = `aigoodbro.home.${id}.expanded`;
  const contentId = useId();
  const [expanded, setExpanded] = useState(() => {
    try { const saved = localStorage.getItem(key); return saved === null ? initialOpen : saved === 'true'; }
    catch { return initialOpen; }
  });
  const open = forceOpen || expanded;
  const toggle = () => {
    const next = !expanded;
    setExpanded(next);
    try { localStorage.setItem(key, String(next)); } catch { /* Session preference still works. */ }
  };
  return { open, contentId, toggle };
}

export function HomeSection({ id, title, children, initialOpen = true, forceOpen = false }: { id: string; title: string; children: ReactNode; initialOpen?: boolean; forceOpen?: boolean }) {
  const { open, contentId, toggle } = useHomeSectionState(id, initialOpen, forceOpen);
  return <section className="space-y-3" data-home-section={id}>
    {forceOpen ? <h2 className="text-sm font-semibold text-primary">{title}</h2> : <button type="button" className="flex items-center gap-2 text-sm font-semibold text-primary rounded-lg focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4"
      aria-expanded={open} aria-controls={contentId} onClick={toggle}>
      {open ? <ChevronDown size={16} /> : <ChevronRight size={16} />} {title}
    </button>}
    <div id={contentId} hidden={!open}>{open && children}</div>
  </section>;
}
