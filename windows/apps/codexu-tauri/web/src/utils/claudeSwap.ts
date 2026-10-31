export interface ClaudeSwapCandidate {
  candidate_id: string;
  label: string;
  masked_identity: string | null;
  already_imported: boolean;
}
export function parseClaudeSwapCandidates(raw: unknown): ClaudeSwapCandidate[] {
  if (!Array.isArray(raw) || raw.length > 64) throw Error('invalid_response');
  const seen = new Set<string>();
  return raw.map(value => {
    if (!value || typeof value !== 'object' || Array.isArray(value)
      || typeof value.candidate_id !== 'string' || !/^[a-f0-9]{64}$/.test(value.candidate_id)
      || seen.has(value.candidate_id) || typeof value.label !== 'string' || !/^Claude [1-9][0-9]{0,4}$/.test(value.label)
      || typeof value.already_imported !== 'boolean'
      || value.masked_identity !== null && (typeof value.masked_identity !== 'string'
        || value.masked_identity.length > 254 || !value.masked_identity.includes('*') || /[\s\\/\x00-\x1f]/.test(value.masked_identity))) throw Error('invalid_response');
    seen.add(value.candidate_id);
    return { candidate_id: value.candidate_id, label: value.label, masked_identity: value.masked_identity, already_imported: value.already_imported };
  });
}
