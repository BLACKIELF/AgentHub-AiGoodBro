import { useState } from 'react';
import { useI18n } from '../i18n/I18nProvider';

const skills = [
  ['Oracle', '调用浏览器，请网页版 GPT 最好的模型复核或出方案', 'Ask the best available GPT in the browser for a second review', '请安装 AiGoodBro 仓库 Resources/SkillLibrary/oracle 中的 Skill，先检查重复项，并按使用说明运行。'],
  ['Handoff · 任务交接', '保存进度、证据与下一步，换任务也能接着做', 'Save progress, evidence and next steps for another task', '请安装 AiGoodBro 仓库 Resources/SkillLibrary/handoff 中的 Skill，先检查重复项，并按使用说明运行。'],
  ['TypeSafe AI', '把自然语言判断变成带概率的类型化结果', 'Turn narrow judgments into typed results with uncertainty', '请安装 AiGoodBro 仓库 Resources/SkillLibrary/typesafe-ai 中的 Skill，先检查重复项，并按使用说明运行。'],
] as const;

export function RecommendedSkills() {
  const { language } = useI18n();
  const [feedback, setFeedback] = useState('');
  const zh = language === 'zh-Hans';
  return <div className="space-y-2"><div className="grid gap-3 sm:grid-cols-3">
    {skills.map(([name, cn, en, prompt]) => <article key={name} className="glass-panel p-4 flex flex-col gap-2 min-w-0">
      <h3 className="text-sm font-semibold text-primary">{name}</h3><p className="text-xs text-secondary flex-1">{zh ? cn : en}</p>
      <button type="button" className="glass-button px-2 py-1.5 text-xs self-start" onClick={async () => {
        try { await navigator.clipboard.writeText(prompt + ' 仓库：https://github.com/BLACKIELF/AgentHub-AiGoodBro'); setFeedback(zh ? '已复制，粘贴到 Codex 即可。' : 'Copied. Paste into Codex.'); }
        catch { setFeedback(zh ? '复制失败，请从仓库查看安装说明。' : 'Copy failed. Open the repository instructions.'); }
      }}>{zh ? '复制安装指令' : 'Copy installation prompt'}</button>
    </article>)}
  </div><p role="status" className="text-xs text-secondary">{feedback || (zh ? '轻唤目前为 macOS 应用；Windows 可使用系统快捷键。Skill 安装不自动授权 API 费用。' : 'Quick Toggle is currently a macOS app. Windows can use system shortcuts. Installing a skill does not authorize API charges.')}</p></div>;
}
