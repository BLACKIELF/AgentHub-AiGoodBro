export type Forecast = { id: string; deadline: number | null; source: string; fetchedAt: number };
export type Notice = { id: string; title: string; body: string; publishedAt: number; expiresAt?: number; source: string | null };
const DAY = 86400000;
const time = (input: unknown) => typeof input === 'string' && /T.*(?:Z|[+-]\d\d:\d\d)$/.test(input) ? Date.parse(input) : NaN;
const object = (input: unknown): Record<string, unknown> => {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid public data');
  return input as Record<string, unknown>;
};
const text = (input: unknown, max: number) => {
  if (typeof input !== 'string' || !input.trim() || new TextEncoder().encode(input).length > max || input.includes('\0')) throw new Error('Invalid public text');
  return input;
};
export function sourceURL(input: unknown, publisher = false): string | null {
  if (input == null) return null;
  const url = new URL(text(input, 2048));
  if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash) throw new Error('Invalid source');
  if (publisher ? url.hostname === 'aigoodbro.com' || (url.hostname === 'github.com' && url.pathname.startsWith('/BLACKIELF/'))
    : url.hostname === 'x.com' && /^\/thsottiaux\/status\/\d{1,20}$/.test(url.pathname)) return url.href;
  throw new Error('Unrecognized source');
}
export function parseForecast(html: string, now: number): Forecast | null {
  if (new TextEncoder().encode(html).length > 1048576 || html.includes('\0') || !html.includes('codex-resets') || !html.includes('hero-figure')) throw new Error('Unknown forecast page');
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const banners = doc.querySelectorAll('[data-role="scheduled-reset"], [data-role="reset-watch"]');
  if (!banners.length) {
    const pending = doc.querySelectorAll('div[data-role="pending-reset"]');
    if (pending.length === 1 && !pending[0].innerHTML.trim()) return null;
    throw new Error('Unknown pending state');
  }
  if (banners.length !== 1) throw new Error('Ambiguous forecast');
  const banner = banners[0];
  if (banner.outerHTML.length > 65536) throw new Error('Oversized forecast');
  const sources = [...new Set([...banner.querySelectorAll('a[href]')].map(link => {
    try { return sourceURL(link.getAttribute('href')); } catch { return null; }
  }).filter((link): link is string => link !== null))];
  if (sources.length !== 1) throw new Error('Missing forecast source');
  const id = sources[0].split('/').pop()!;
  const announced = Number((BigInt(id) >> 22n) + 1288834974657n);
  const scheduled = banner.getAttribute('data-role') === 'scheduled-reset';
  const raw = banner.getAttribute(scheduled ? 'data-scheduled-for' : 'data-expires-at');
  const deadline = raw === null && !scheduled ? null : time(raw);
  if (announced > now + 300000 || announced < now - 90 * DAY || (deadline !== null && (!Number.isFinite(deadline) || deadline < announced - 300000 || deadline > now + 14 * DAY))) throw new Error('Invalid forecast time');
  return { id, deadline, source: sources[0], fetchedAt: now };
}
export function parseNotices(raw: string, now: number, publisher: boolean): Notice[] {
  if (new TextEncoder().encode(raw).length > (publisher ? 65536 : 524288)) throw new Error('Oversized feed');
  const feed = object(JSON.parse(raw));
  const items = publisher ? feed.messages : feed.data;
  if (publisher ? feed.version !== 1 : object(feed.meta).api_version !== 'v1' || Math.abs(time(object(feed.meta).generated_at) - now) > DAY || !Number.isFinite(time(object(feed.meta).generated_at))) throw new Error('Unsupported feed');
  if (!Array.isArray(items) || items.length > (publisher ? 50 : 100)) throw new Error('Invalid feed size');
  const notices = items.map(input => {
    const value = object(input);
    const id = text(value.id, 64);
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error('Invalid notice ID');
    const publishedAt = time(publisher ? value.publishedAt : value.announced_at);
    const expiresAt = publisher ? time(value.expiresAt) : undefined;
    if (!Number.isFinite(publishedAt) || (publisher && (!Number.isFinite(expiresAt) || expiresAt! <= publishedAt || expiresAt! - publishedAt > 90 * DAY))) throw new Error('Invalid notice time');
    let source: string | null;
    if (publisher) source = sourceURL(value.url, true);
    else {
      const origin = object(value.source);
      source = sourceURL(origin.url);
      if (origin.type === 'x_post') {
        if (origin.author !== 'thsottiaux' || !source?.endsWith('/' + id)) throw new Error('Unverified history');
      } else if (origin.type !== 'observed' || origin.author != null || !id.startsWith('observed-')) throw new Error('Unverified observation');
      if (!['regular', 'banked'].includes(String(value.reset_type)) || publishedAt > now + 300000 || publishedAt <= 1700000000000) throw new Error('Invalid history');
    }
    return { id, title: publisher ? text(value.title, 240) : value.reset_type === 'banked' ? 'Reset cards · 重置卡公告' : 'Quota reset · 额度重置公告',
      body: text(publisher ? value.body : value.text, publisher ? 2000 : 16384), publishedAt, expiresAt, source };
  });
  if (new Set(notices.map(item => item.id)).size !== notices.length) throw new Error('Duplicate notices');
  return notices.filter(item => item.publishedAt <= now && (item.expiresAt === undefined || item.expiresAt > now))
    .sort((a, b) => b.publishedAt - a.publishedAt || a.id.localeCompare(b.id));
}
