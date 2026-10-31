import { useEffect, useRef, useState } from 'react';
import { ProviderMark } from './ProviderMark';
import { useI18n } from '../i18n/I18nProvider';
const valid = (raw: unknown): raw is string => typeof raw === 'string' && raw.length <= 180000 && /^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(raw);
function read(key: string) { try { const value = localStorage.getItem(key); return valid(value) ? value : null; } catch { return null; } }
export function LocalAccountAvatar({ id, provider, label }: { id: string; provider: string; label: string }) {
  const key = 'AiGoodBro.account.avatar.' + provider + '.' + id, { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [avatar, setAvatar] = useState(() => read(key)), [error, setError] = useState(false), generation = useRef(0);
  useEffect(() => { generation.current++; setAvatar(read(key)); return () => { generation.current++; }; }, [key]);
  const save = (value: string | null) => { try { if (value) localStorage.setItem(key, value); else localStorage.removeItem(key); setAvatar(value); setError(false); } catch { setError(true); } };
  const choose = async (file?: File) => {
    if (!file) return; const epoch = ++generation.current;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || file.size > 5 * 1024 * 1024) { setError(true); return; }
    let bitmap: ImageBitmap | undefined;
    try { bitmap = await createImageBitmap(file); const canvas = document.createElement('canvas'); canvas.width = canvas.height = 96; const ctx = canvas.getContext('2d'); if (!ctx) throw Error(); const side = Math.min(bitmap.width, bitmap.height); ctx.drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, 96, 96); const value = canvas.toDataURL('image/png'); if (!valid(value)) throw Error(); if (epoch === generation.current) save(value); }
    catch { if (epoch === generation.current) setError(true); } finally { bitmap?.close(); }
  };
  return <details className="local-account-avatar"><summary aria-label={text('更换头像', 'Change avatar') + ' · ' + label}>{avatar ? <img src={avatar} alt="" width={24} height={24}/> : <ProviderMark provider={provider} size={24}/>}</summary><div className="avatar-menu"><label>{text('选择本机图片', 'Choose a local image')}<input type="file" accept="image/png,image/jpeg,image/webp" aria-label={text('头像图片', 'Avatar image') + ' · ' + label} onChange={event => { void choose(event.target.files?.[0]); event.target.value = ''; }}/></label><button type="button" disabled={!avatar} onClick={() => { generation.current++; save(null); }}>{text('恢复平台图标', 'Use provider icon')}</button><p>{text('仅保存在本机', 'Saved on this device only')}</p>{error && <p role="alert">{text('图片未保存，请使用小于 5 MB 的 PNG、JPEG 或 WebP。', 'Image not saved. Use PNG, JPEG or WebP below 5 MB.')}</p>}</div></details>;
}
