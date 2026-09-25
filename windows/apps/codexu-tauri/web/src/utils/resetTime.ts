export type ResetKind = 'account' | 'forecast';

export function resetCountdown(deadline: number | null, now: number, kind: ResetKind, chinese: boolean): string {
  if (deadline === null || !Number.isFinite(deadline) || !Number.isFinite(now) || Math.abs(deadline) > 8.64e15 || Math.abs(now) > 8.64e15 || !Number.isSafeInteger(Math.ceil(Math.abs(deadline - now)))) {
    return chinese ? '重置时间未知' : 'Reset time unknown';
  }
  const seconds = Math.max(0, Math.ceil((deadline - now) / 1000));
  if (seconds === 0) return kind === 'forecast'
    ? (chinese ? '预告时间已到，等待来源确认' : 'Forecast time reached; awaiting confirmation')
    : (chinese ? '时间已到，等待额度更新' : 'Time reached; awaiting quota update');
  const days = Math.floor(seconds / 86400);
  const clock = [Math.floor(seconds % 86400 / 3600), Math.floor(seconds % 3600 / 60), seconds % 60]
    .map(value => String(value).padStart(2, '0')).join(':');
  const prefix = kind === 'forecast' ? (chinese ? '最晚还有 ' : 'Due within ') : (chinese ? '重置还有 ' : 'Resets in ');
  return prefix + (days ? `${days}${chinese ? ' 天 ' : 'd '}` : '') + clock;
}
