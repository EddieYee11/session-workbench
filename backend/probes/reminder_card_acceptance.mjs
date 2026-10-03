// Exercise the existing installed reminder tool without a model or message delivery.
import {createRequire} from 'node:module';
import {writeFileSync} from 'node:fs';
const root='/usr/local/lib/node_modules/@earendil-works/pi-coding-agent';
const require=createRequire(root+'/dist/index.js');
const {createJiti}=await import(root+'/node_modules/jiti/lib/jiti.mjs');
const jiti=createJiti(root+'/dist/index.js',{alias:{typebox:require.resolve('typebox'),'@earendil-works/pi-ai':root+'/node_modules/@earendil-works/pi-ai/dist/compat.js'}});
const mod=await jiti.import(process.env.HOME+'/.pi-gateway/extensions/remind.ts');
let tool;mod.default({registerTool(t){tool=t;}});
const ids=[];
for(const action of ['confirm','snooze10','snooze60','cancel']){
 const result=await tool.execute('com-b3-probe-'+action,{action:'add',text:'Com B3 验收临时提醒 '+action,at:'2099-01-01 12:00',repeat:'once',mode:'direct'});
 ids.push({action,id:result.details.id});
}
writeFileSync('/tmp/com-b3-reminder-ids.json',JSON.stringify(ids),{mode:0o600});
console.log(JSON.stringify({created:ids.length,source:'existing remind extension',due:'2099-01-01 12:00'}));
