import React, {useState} from 'react';
import {createRoot} from 'react-dom/client';
import {VoiceBeam} from 'voice-glow';

window.comMeter = {level: 0, processing: false, active: true, paused: false, theme: 'light'};
let notifyState;
window.comVoiceUpdate = (next) => {
  const old = window.comMeter;
  window.comMeter = {...old, ...next};
  if (['processing','active','paused','theme'].some(k => old[k] !== window.comMeter[k])) notifyState?.({...window.comMeter});
};
function VoiceSurface() {
  const [state, setState] = useState(window.comMeter);
  notifyState = setState;
  return <VoiceBeam type="mobile" level={() => window.comMeter.level}
    motion={() => window.comMeter.processing ? {gather:0.9, offset:Math.sin(performance.now()/650)*0.7, heldLevel:0.5, stretch:0.15} : {gather:0}}
    active={state.active} paused={state.paused}
    theme={state.theme} colorVariant="colorful" sensitivity={1.2}
    threshold={0.035} attack={0.09} release={0.42}
    reach={1.15} spread={0.65} strength={0.85}
    style={{width:'100%',height:'100%'}}>
    <div style={{width:'100%',height:'100%',borderRadius:28,background:'transparent'}} />
  </VoiceBeam>;
}
createRoot(document.getElementById('root')).render(<VoiceSurface />);
