// Swift Character parity: count extended grapheme clusters, not UTF-16 units.
const invalid = () => { throw Error('invalid_label'); };
function graphemes(value: string): string[] {
  const Segmenter = (Intl as unknown as { Segmenter?: new (locale: string, options: { granularity: 'grapheme' }) => { segment(value: string): Iterable<{ segment: string }> } }).Segmenter;
  if (!Segmenter) return invalid();
  return Array.from(new Segmenter('en', { granularity: 'grapheme' }).segment(value), entry => entry.segment);
}
export function normalizeAccountRemark(value: string): string {
  if (new TextEncoder().encode(value).length > 16384) return invalid();
  const trimmed = value.trim(); if (!trimmed) return '';
  if (/[\x00-\x1f\x7f-\x9f@/\\:]/.test(trimmed)) return invalid();
  return graphemes(trimmed).slice(0, 40).join('');
}
export function validAccountRemark(value: string): boolean { try { normalizeAccountRemark(value); return true; } catch { return false; } }
export function validAccountDisplayLabel(value: unknown): value is string {
  if (typeof value !== 'string' || !value || value !== value.trim()) return false;
  try { return !/[\x00-\x1f\x7f-\x9f@/\\:]/.test(value) && (new TextEncoder().encode(value).length <= 64 || normalizeAccountRemark(value) === value); } catch { return false; }
}
export function parseAccountOrder(raw: unknown, submitted: readonly string[]): string[] {
  if (!Array.isArray(raw) || raw.length > 64 || raw.length !== submitted.length || new Set(raw).size !== raw.length || raw.some((id, index) => typeof id !== 'string' || !/^[a-f0-9]{32}$/.test(id) || id !== submitted[index])) throw Error('invalid_response');
  return raw as string[];
}
