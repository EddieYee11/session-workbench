import {build} from 'esbuild';
import {readFile, writeFile, copyFile, mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(here, '../Com/Resources');
await mkdir(output, {recursive:true});
const result = await build({entryPoints:[path.join(here,'voice.jsx')],bundle:true,minify:true,
  write:false,format:'iife',target:['safari17'],define:{'process.env.NODE_ENV':'"production"'}});
const code = result.outputFiles[0].text.replaceAll('</script','<\\/script');
const html = `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; media-src 'none'"><style>html,body,#root{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}*{box-sizing:border-box}body{pointer-events:none}</style></head><body><div id="root"></div><script>${code}</script></body></html>`;
await writeFile(path.join(output,'VoiceBeam.html'),html);
await copyFile(path.join(here,'node_modules/voice-glow/LICENSE'),path.join(output,'VoiceGlow-LICENSE.txt'));
const notices = await Promise.all(['react','react-dom'].map(async name => name + '\n' + await readFile(path.join(here,'node_modules',name,'LICENSE'),'utf8')));
await writeFile(path.join(output,'VoiceGlow-ThirdParty-LICENSE.txt'),notices.join('\n\n'));
const destination = path.resolve(here,'../../android/app/src/main/assets');
await mkdir(destination,{recursive:true});
await writeFile(path.join(destination,'VoiceBeam.html'),html);
await copyFile(path.join(output,'VoiceGlow-LICENSE.txt'),path.join(destination,'VoiceGlow-LICENSE.txt'));
await copyFile(path.join(output,'VoiceGlow-ThirdParty-LICENSE.txt'),path.join(destination,'VoiceGlow-ThirdParty-LICENSE.txt'));
console.log(`Built offline voice-glow 0.3.0: ${Buffer.byteLength(html)} bytes; iOS + Android`);
