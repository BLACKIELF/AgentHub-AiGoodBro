import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import {createServer} from 'node:http';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const types = {'.html':'text/html; charset=utf-8','.mjs':'text/javascript; charset=utf-8',
  '.json':'application/json; charset=utf-8','.md':'text/plain; charset=utf-8',
  '.png':'image/png','.wav':'audio/wav','.mp4':'video/mp4'};

// Loopback-only static server, with byte ranges for the native media player.
export async function serve(root = here, port = 0) {
  root = await fsp.realpath(root);
  const server = createServer(async (req, res) => {
    try {
      if (!['GET','HEAD'].includes(req.method)) return res.writeHead(405).end();
      const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
      const candidate = path.resolve(root, '.' + (name === '/' ? '/index.html' : name));
      if (!candidate.startsWith(root + path.sep)) return res.writeHead(403).end();
      const file = await fsp.realpath(candidate);
      if (!file.startsWith(root + path.sep)) return res.writeHead(403).end();
      const stat = await fsp.stat(file);
      if (!stat.isFile()) return res.writeHead(404).end();
      let start = 0, end = stat.size - 1, status = 200;
      const headers = {'Content-Type':types[path.extname(file)] || 'application/octet-stream',
        'Accept-Ranges':'bytes','Cache-Control':'no-store'};
      if (req.headers.range) {
        const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
        if (!match || (!match[1] && !match[2])) return res.writeHead(416, {'Content-Range':`bytes */${stat.size}`}).end();
        if (!match[1]) start = Math.max(0, stat.size - Number(match[2]));
        else { start = Number(match[1]); if (match[2]) end = Math.min(end, Number(match[2])); }
        if (start > end || start >= stat.size) return res.writeHead(416, {'Content-Range':`bytes */${stat.size}`}).end();
        status = 206; headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
      }
      headers['Content-Length'] = end - start + 1;
      res.writeHead(status, headers);
      if (req.method === 'HEAD') return res.end();
      const stream = fs.createReadStream(file, {start,end});
      stream.on('error', () => res.destroy());
      res.on('close', () => stream.destroy());
      stream.pipe(res);
    } catch { if (!res.headersSent) res.writeHead(404).end(); else res.destroy(); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  return {server, origin:`http://127.0.0.1:${server.address().port}`};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.argv[2] || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('Use a port between 1 and 65535.');
  const {server, origin} = await serve(here, port);
  console.log(`Open ${origin}/ — stop with Ctrl+C.`);
  process.on('SIGINT', () => server.close(() => process.exit(0)));
}
