import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import type { Plugin } from 'vite';

// The same production controller/chart code used by Mac is shipped unchanged.
// Only the copied HTML adds a sandboxed, message-only Windows host adapter.
const charts = fileURLToPath(new URL('../../../../../Resources/UpstreamCharts/', import.meta.url));
const host = fileURLToPath(new URL('./token-monitor-host.js', import.meta.url));
const assets = ['home-dashboard.html','home-dashboard.css','home-dashboard.js','home-bridge.js','LICENSE-token-monitor','SOURCE-NOTICE.txt',
  'desktop/SOURCE.json','desktop/dashboard.css','desktop/dashboard.js','desktop/usageCharts.js','desktop/themePresets.js','desktop/i18n.js',
  'desktop/compactTokens.js','desktop/currency.js','desktop/compactMoney.js','desktop/fontSettings.js','desktop/motionPreference.js','desktop/statsRenderScheduler.js'];
export function tokenMonitorCharts(): Plugin {
  const entries = new Map(assets.map(name => [name, readFileSync(charts + name)]));
  const pins = Object.fromEntries([...entries].map(([name, bytes]) => [name, createHash('sha256').update(bytes).digest('hex')]));
  const html = entries.get('home-dashboard.html')!.toString('utf8').replace('</body>', '<script src="windows-host.js"></script></body>');
  entries.set('home-dashboard.html', Buffer.from(html));
  entries.set('windows-host.js', readFileSync(host));
  entries.set('SOURCE-WINDOWS.json', Buffer.from(JSON.stringify({schemaVersion:1,source:'Resources/UpstreamCharts',files:pins,htmlAdaptation:'Append message-only sandbox host script; no source controller changes'},null,2)+'\n'));
  return {
    name:'aigoodbro-token-monitor-charts',
    configureServer(server) {
      server.middlewares.use((request,response,next) => {
        const name=(request.url||'').split('?')[0].replace(/^\/token-monitor-home\//,'');
        if(!request.url?.startsWith('/token-monitor-home/'))return next();
        const bytes=entries.get(name);
        if(!bytes){response.statusCode=404;response.end();return;}
        response.setHeader('Content-Type',name.endsWith('.js')?'text/javascript; charset=utf-8':name.endsWith('.css')?'text/css; charset=utf-8':name.endsWith('.html')?'text/html; charset=utf-8':'application/json; charset=utf-8');
        response.setHeader('Cache-Control','no-store');response.end(bytes);
      });
    },
    generateBundle() { for(const [name,source] of entries)this.emitFile({type:'asset',fileName:'token-monitor-home/'+name,source}); },
  };
}
