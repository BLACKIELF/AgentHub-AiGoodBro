import fs from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {serve} from './serve.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const mode = process.argv[2] || 'stills';
const options = Object.fromEntries(process.argv.slice(3).map(value => {
  const match = /^--(frames|start|duration|output)=(.+)$/.exec(value);
  if (!match) throw Error('Options use --frames=…, --start=…, --duration=…, or --output=….');
  return [match[1], match[2]];
}));
if (!['stills','short','full','score'].includes(mode)) throw Error('Use stills, short, full, or score.');
const allowed = {stills:['frames','output'],short:['start','duration','output'],full:['output'],score:['output']};
if (Object.keys(options).some(key => !allowed[mode].includes(key))) throw Error(`Unsupported option for ${mode}.`);
const cues = JSON.parse(await fs.readFile(path.join(here,'cues-en-1011v1.json'),'utf8'));
const fps = 30, width = 1920, height = 1440;
const total = Math.round(cues.duration * fps);
const digest = data => createHash('sha256').update(data).digest('hex');
const relative = file => path.relative(here,file).split(path.sep).join('/');
const outputPath = value => {
  const file = path.resolve(here,value);
  if (!file.startsWith(path.join(here,'generated') + path.sep)) throw Error('Output must stay inside generated/.');
  return file;
};
const exists = async file => fs.access(file).then(() => true, () => false);
const run = (command,args,stdio = ['ignore','ignore','inherit']) => {
  const child = spawn(command,args,{cwd:here,stdio});
  const done = new Promise((resolve,reject) => {
    child.once('error',reject);
    child.once('close',code => code === 0 ? resolve() : reject(Error(`${command} exit ${code}`)));
  });
  done.catch(() => {});
  return {child,done};
};

if (mode === 'score') {
  const output = outputPath(options.output || 'generated/reference-score-rerender.wav');
  if (await exists(output)) throw Error(`Output already exists: ${relative(output)}`);
  await fs.mkdir(path.dirname(output),{recursive:true});
  const input = outputPath('generated/score-input.json');
  // The unmodified score source expects "dur"; the original exported cues use "duration".
  await fs.writeFile(input,JSON.stringify({...cues,dur:cues.duration}) + '\n');
  await run(process.env.AGB_PYTHON || 'python3',['score-en-1011v1.py',relative(input),relative(output)]).done;
  console.log(JSON.stringify({mode,output:relative(output)}));
} else {
  const originalInputs = JSON.parse(await fs.readFile(path.join(here,'ORIGINALS.json'),'utf8'));
  for (const asset of originalInputs.external_required_assets || []) {
    const file = path.join(here,asset.path);
    if (!await exists(file)) {
      console.error(`Required user-supplied image is missing: ${asset.path}. See ui/README.md; no replacement is downloaded or substituted.`);
      process.exit(2);
    }
    if (digest(await fs.readFile(file)) !== asset.sha256) {
      console.error(`User-supplied image does not match the documented source: ${asset.path}. See ui/README.md.`);
      process.exit(2);
    }
  }
  let runtime;
  try { runtime = require(process.env.AGB_PLAYWRIGHT || 'playwright'); }
  catch {
    if (process.env.AGB_PLAYWRIGHT) throw Error('AGB_PLAYWRIGHT could not be loaded.');
    try { runtime = require('playwright-core'); }
    catch { throw Error('Use an existing Playwright installation via AGB_PLAYWRIGHT, or a locally resolvable playwright/playwright-core package.'); }
  }
  let frames, output;
  if (mode === 'stills') {
    frames = (options.frames || '60,213,462,621,744,846,948,1320').split(',').map(Number);
    if (!frames.length || frames.some(f => !Number.isInteger(f) || f < 0 || f >= total)) throw Error(`Frames must be integers from 0 to ${total-1}.`);
    output = outputPath(options.output || 'generated/stills');
    for (const f of frames) if (await exists(path.join(output,`english-${String(f).padStart(4,'0')}.png`))) throw Error('A requested still already exists. Use another generated/ output directory.');
    await fs.mkdir(output,{recursive:true});
  } else {
    const start = mode === 'full' ? 0 : Number(options.start ?? 13.6);
    const duration = mode === 'full' ? cues.duration : Number(options.duration ?? 2.8);
    if (!Number.isFinite(start) || !Number.isFinite(duration) || start < 0 || duration <= 0 || start + duration > cues.duration + 1e-7) throw Error('Choose a positive interval within the 48-second scene.');
    if (Math.abs(start*fps-Math.round(start*fps)) > 1e-7 || Math.abs(duration*fps-Math.round(duration*fps)) > 1e-7) throw Error('Start and duration must align to 30 fps.');
    frames = Array.from({length:Math.round(duration*fps)},(_,i) => Math.round(start*fps)+i);
    output = outputPath(options.output || (mode === 'full' ? 'generated/AiGoodBro-English-rerender.mp4' : 'generated/notification-sample.mp4'));
    if (await exists(output)) throw Error(`Output already exists: ${relative(output)}`);
    await fs.mkdir(path.dirname(output),{recursive:true});
  }
  const reportFile = mode === 'stills' ? path.join(output,'render-check.json') : output + '.json';
  if (await exists(reportFile)) throw Error('A render report already exists. Choose another output.');
  const {server,origin} = await serve(here);
  let browser, encoder;
  const errors = [], requests = [], blocked = [], rendered = [];
  try {
    browser = await runtime.chromium.launch({headless:true,
      ...(process.env.AGB_CHROME ? {executablePath:process.env.AGB_CHROME} : {}),
      args:['--disable-background-networking','--no-first-run','--no-default-browser-check']});
    const page = await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
    page.on('pageerror',() => errors.push('scene_script_error'));
    page.on('response',response => { if (response.status() >= 400) requests.push({path:new URL(response.url()).pathname,status:response.status()}); });
    await page.route('**/*',route => {
      const url = route.request().url();
      if (url.startsWith(origin+'/') || url.startsWith('data:')) return route.continue();
      blocked.push('external_request'); return route.abort();
    });
    await page.goto(origin+'/scene-en-1011v1.html?rec=1');
    await page.evaluate(() => window.sceneReady);
    const meta = await page.evaluate(() => ({duration:window.__dur,bpm:window.__bpm,beats:window.__beats,cues:window.__cues,
      images:[...document.images].map(i => ({src:i.getAttribute('src'),loaded:i.complete && i.naturalWidth > 0}))}));
    if (meta.duration !== cues.duration || meta.bpm !== cues.bpm || meta.beats !== cues.beats || JSON.stringify(meta.cues) !== JSON.stringify(cues.cues)) throw Error('Scene metadata does not match original cues.');
    if (meta.images.some(i => !i.loaded)) throw Error('An original scene image did not load.');
    if (mode !== 'stills') {
      encoder = run(process.env.AGB_FFMPEG || 'ffmpeg',['-v','error','-n','-f','image2pipe','-framerate',String(fps),'-c:v','mjpeg','-i','pipe:0',
        '-ss',String(frames[0]/fps),'-i','audio/reference-score-1011v1.wav','-map','0:v:0','-map','1:a:0',
        '-c:v','libx264','-preset','medium','-crf','16','-pix_fmt','yuv420p','-c:a','aac','-b:a','256k',
        '-frames:v',String(frames.length),'-t',String(frames.length/fps),'-movflags','+faststart',relative(output)],['pipe','ignore','inherit']);
      encoder.child.stdin.on('error',() => {});
    }
    // The retained source has styles that can depend on a preceding hover phase.
    // Advance its original clock in order, including uncaptured frames; do not patch the scene.
    let previousFrame = -1;
    for (const frame of frames) {
      if (frame < previousFrame) {
        await page.reload();
        await page.evaluate(() => window.sceneReady);
        previousFrame = -1;
      }
      await page.evaluate(async ({from,to,fps}) => {
        for (let current=from;current<=to;current++) await window.renderAt(current/fps);
      },{from:previousFrame+1,to:frame,fps});
      previousFrame = frame;
      const data = await page.screenshot(mode === 'stills' ? {type:'png'} : {type:'jpeg',quality:95});
      if (mode === 'stills') {
        const name = `english-${String(frame).padStart(4,'0')}.png`;
        await fs.writeFile(path.join(output,name),data,{flag:'wx'});
        rendered.push({frame,seconds:frame/fps,path:relative(path.join(output,name)),sha256:digest(data)});
      } else {
        if (encoder.child.exitCode !== null) throw Error('Encoder ended before all frames were sent.');
        if (!encoder.child.stdin.write(data)) await Promise.race([once(encoder.child.stdin,'drain'),encoder.done.then(() => { throw Error('Encoder ended early.'); })]);
      }
      if (errors.length || requests.length || blocked.length) throw Error('Scene loading or rendering failed.');
    }
    if (encoder) { encoder.child.stdin.end(); await encoder.done; }
    const report = {mode,source:'scene-en-1011v1.html',source_sha256:digest(await fs.readFile(path.join(here,'scene-en-1011v1.html'))),
      output:relative(output),frames_rendered:frames.length,first_frame:frames[0],last_frame:frames.at(-1),
      first_source_time:frames[0]/fps,duration:mode === 'stills' ? null : frames.length/fps,width,height,fps,
      scene_duration:meta.duration,bpm:meta.bpm,beats:meta.beats,cue_count:meta.cues.length,cues_match:true,
      sequential_source_frames:true,
      images:meta.images,errors,failed_requests:requests,blocked_requests:blocked,node:process.version,browser:browser.version(),rendered,
      scope:'Local promotional scene render; no application backend or subjective listening review was tested.'};
    await fs.writeFile(reportFile,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
    console.log(JSON.stringify({mode,output:relative(output),frames:frames.length,report:relative(reportFile),errors:errors.length}));
  } finally {
    if (encoder?.child.exitCode === null) encoder.child.kill('SIGTERM');
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}
