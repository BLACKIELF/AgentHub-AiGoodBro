import { useEffect, useRef } from 'react';
import { useI18n } from '../i18n/I18nProvider';

export function CodexAccountGuide({ onClose }: { onClose: () => void }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const node = dialog.current;
    const previous = document.activeElement;
    node?.showModal();
    return () => { node?.close(); if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); };
  }, []);
  return (
    <dialog ref={dialog} aria-labelledby="codex-account-guide-title" onCancel={onClose} className="m-auto w-[calc(100%-2rem)] max-w-xl max-h-[90vh] overflow-auto rounded-2xl bg-surface text-primary p-0 backdrop:bg-black/50">
      <section aria-labelledby="codex-account-guide-title" className="glass-panel w-full max-w-xl space-y-4 p-5 shadow-2xl">
        <header className="flex items-center justify-between gap-3">
          <h3 id="codex-account-guide-title" className="font-semibold text-primary">{text('添加 Codex 账号', 'Add a Codex account')}</h3>
          <button className="glass-button px-3 py-1.5 text-sm" onClick={onClose}>{text('关闭', 'Close')}</button>
        </header>
        <ol className="list-decimal space-y-3 pl-5 text-sm text-secondary">
          <li>{text('为每个账号创建独立目录，并在新的 PowerShell 窗口中将 CODEX_HOME 指向该目录。不要复用当前账号目录。', 'Create a separate directory for each account. In a new PowerShell window, point CODEX_HOME to that directory; do not reuse another account directory.')}</li>
          <li>{text('在该独立 CODEX_HOME 下运行 Codex 当前支持的登录流程（codex login），完成你自己的账号登录。此应用不会代填或保存凭据。', 'Under that independent CODEX_HOME, run the currently supported Codex login flow (codex login) and sign in to your own account. This app does not enter or store credentials for you.')}</li>
          <li>{text('回到这里选择“关联已有目录”，为目录填写不含邮箱的备注。关联仅保存目录关系，不会切换 Codex 登录。', 'Return here, choose “Link existing directory,” and use a non-email alias. Linking stores only the directory relationship and does not switch Codex login.')}</li>
          <li>{text('点击该账号行的“读取额度”，核对套餐、账号类型、5 小时/7 天窗口和官方来源。读取失败或过期时不要把旧值视为当前额度。', 'Select “Read quota” on that account row and verify the plan, account type, 5-hour/7-day windows, and official source. A failed or expired read is not current quota.')}</li>
        </ol>
        <p className="rounded-xl border border-theme p-3 text-xs text-tertiary">{text('建议的 PowerShell 形式：先设置 `$env:CODEX_HOME` 为你新建的独立目录，再运行 `codex login`。请勿把目录路径、凭据或登录输出贴到备注中。', 'Suggested PowerShell flow: set `$env:CODEX_HOME` to the new independent directory, then run `codex login`. Never paste paths, credentials, or login output into an alias.')}</p>
      </section>
    </dialog>
  );
}
