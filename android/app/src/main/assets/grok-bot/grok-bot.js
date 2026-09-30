/* Local Lottie artwork + independent business/interaction controller. */
(() => {
  const labels={idle:'安静陪伴',listening:'认真听你说',thinking:'让我想一想',speaking:'有想法，和你分享',happy:'好耶，搞定了',curious:'嗯？再说一点',greeting:'嗨，很高兴见到你',upload:'正在上传',error:'需要你帮忙',annoyed:'好啦，我还在忙呢',dizzy:'晕乎乎，缓一下'};
  const blockedGaze=new Set(['happy','annoyed','dizzy','error','greeting']);
  class GrokBot extends HTMLElement {
    connectedCallback(){
      if(this._mounted)return;
      const resumeState=this._savedState||this.getAttribute('state')||'idle';
      this._mounted=true;this._state='idle';this._visible=true;this._paused??=false;this._progress??=0;
      this._media=matchMedia('(prefers-reduced-motion: reduce)');
      this._target=[0,0];this._look=[0,0];this._raf=0;this._lastFrame=0;
      const root=this.shadowRoot||this.attachShadow({mode:'open'});
      root.innerHTML=`<style>:host{display:block;position:relative;aspect-ratio:1;contain:layout style;outline-offset:-20px}.stage{position:absolute;inset:0;transition:opacity .13s ease}.progress{position:absolute;inset:0;width:100%;height:100%;pointer-events:none;opacity:0;transition:opacity .2s}.progress.active{opacity:1}.track{stroke:currentColor;opacity:.07}.meter{stroke:#beadff;stroke-linecap:round;transition:stroke-dashoffset .28s ease}.gaze{transform-box:view-box}:host([reduced-motion]) *{transition:none!important}@media(prefers-reduced-motion:reduce){*{transition:none!important}}</style><svg class="progress" viewBox="0 0 512 512" aria-hidden="true"><circle class="track" cx="256" cy="274" r="150" fill="none" stroke-width="3"/><circle class="meter" cx="256" cy="274" r="150" fill="none" stroke-width="4" stroke-dasharray="942.478" stroke-dashoffset="942.478" transform="rotate(-90 256 274)"/></svg>`;
      this._stages=[0,1].map(()=>{const n=document.createElement('div');n.className='stage';root.appendChild(n);return n;});
      this._animations=[null,null];this._gazeGroups=[[],[]];this._active=0;this._token=0;
      this._sync=()=>{
        const suspended=document.hidden||!this._visible||this._paused;
        for(const a of this._animations){if(!a)continue;if(suspended)a.pause();else if(this._reducedMotion)a.goToAndStop(Math.min(60,a.totalFrames-1),true);else a.play();}
        if(suspended||this._reducedMotion){cancelAnimationFrame(this._raf);this._raf=0;}else this._wakeGaze();
      };
      document.addEventListener('visibilitychange',this._sync);this._media.addEventListener('change',this._sync);
      this._observer=new IntersectionObserver(entries=>{this._visible=entries[0].isIntersecting;this._sync();});this._observer.observe(this);
      this._pointer=e=>{
        if(!this._visible||this._paused||document.hidden)return;
        const r=this.getBoundingClientRect();
        const x=Math.max(-1,Math.min(1,(e.clientX-r.left-r.width/2)/(r.width*.62)));
        const y=Math.max(-1,Math.min(1,(e.clientY-r.top-r.height*.50)/(r.height*.62)));
        this._target=[x,y];this._wakeGaze();
      };
      this._resetGaze=()=>{this._target=[0,0];this._wakeGaze();};
      this._tap=()=>this.react('poke');
      this._key=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();this.react('poke');}};
      document.addEventListener('pointermove',this._pointer,{passive:true});document.addEventListener('pointerleave',this._resetGaze);
      this.addEventListener('pointerdown',this._pointer,{passive:true});this.addEventListener('pointerup',this._resetGaze);
      this.addEventListener('click',this._tap);this.addEventListener('keydown',this._key);
      this.setAttribute('role','button');if(!this.hasAttribute('tabindex'))this.tabIndex=0;
      this._controller=new BotController({onChange:(state,meta)=>this._renderState(state,meta)});
      if(resumeState!=='idle')this.setState(resumeState);
      this.setProgress(this._progress);
    }
    _renderState(state,meta){
      const token=++this._token;clearTimeout(this._cleanup);const prev=this._active,next=1-prev;
      this._animations[next]?.destroy();this._stages[next].innerHTML='';this._stages[next].style.opacity='0';this._gazeGroups[next]=[];
      this._state=state;this._meta=meta;this.setAttribute('aria-label',labels[state]+'；轻点互动');
      this.shadowRoot.querySelector('.progress').classList.toggle('active',meta.baseState==='upload');
      const data=JSON.parse(JSON.stringify(window.GROK_BOT_DATA[state]));
      if(meta.temporary&&['thinking','upload'].includes(meta.baseState)){
        const base=window.GROK_BOT_DATA[meta.baseState];
        for(const name of ['Status badge','Soft sphere']){
          data.layers.find(l=>l.nm===name).shapes=JSON.parse(JSON.stringify(base.layers.find(l=>l.nm===name).shapes));
        }
      }
      const a=lottie.loadAnimation({container:this._stages[next],renderer:'svg',loop:!['happy','greeting','annoyed','dizzy'].includes(state),autoplay:false,animationData:data,rendererSettings:{preserveAspectRatio:'xMidYMid meet'}});
      this._animations[next]=a;this._active=next;
      a.addEventListener('DOMLoaded',()=>{
        if(!this._mounted||token!==this._token)return;
        this._gazeGroups[next]=[...this._stages[next].querySelectorAll('[id^="bot-face-"]')].map(el=>{const g=document.createElementNS('http://www.w3.org/2000/svg','g');g.classList.add('gaze');el.parentNode.insertBefore(g,el);g.appendChild(el);return g;});
        this._applyGaze();a.goToAndStop(this._reducedMotion?Math.min(60,a.totalFrames-1):0,true);
        this._stages[next].style.opacity='1';this._stages[prev].style.opacity='0';this._sync();
        this._cleanup=setTimeout(()=>{if(token===this._token){this._animations[prev]?.destroy();this._animations[prev]=null;this._gazeGroups[prev]=[];this._stages[prev].innerHTML='';}},160);
      });
      this._wakeGaze();this.dispatchEvent(new CustomEvent('statechange',{detail:{state,...meta},bubbles:true}));
    }
    _wakeGaze(){
      if(this._raf||!this._mounted||this._paused||!this._visible||document.hidden||this._reducedMotion)return;
      this._lastFrame=performance.now();this._raf=requestAnimationFrame(t=>this._tickGaze(t));
    }
    _tickGaze(now){
      this._raf=0;const dt=Math.min(50,now-this._lastFrame);this._lastFrame=now;
      const target=blockedGaze.has(this._state)?[0,0]:this._target,gain=1-Math.exp(-dt/95);
      for(let i=0;i<2;i++)this._look[i]+=(target[i]-this._look[i])*gain;
      this._applyGaze();
      if(Math.abs(target[0]-this._look[0])+Math.abs(target[1]-this._look[1])>.003)this._raf=requestAnimationFrame(t=>this._tickGaze(t));
    }
    _applyGaze(){
      const strength=['thinking','upload','speaking'].includes(this._state) ? 0.5 : 1,[x,y]=this._look;
      const transform=`translate(${(x*30*strength).toFixed(3)} ${(y*19*strength).toFixed(3)}) translate(256 274) scale(${(1-Math.abs(x)*.10).toFixed(4)} 1) translate(-256 -274)`;
      for(const groups of this._gazeGroups)for(const g of groups)g.setAttribute('transform',transform);
    }
    get _reducedMotion(){return this._forceReducedMotion||this._media?.matches;}
    setReducedMotion(value){this._forceReducedMotion=Boolean(value);this.toggleAttribute('reduced-motion',this._forceReducedMotion);if(this._reducedMotion){this._look=[0,0];this._target=[0,0];this._applyGaze?.();}this._sync?.();}
    setState(state){if(!this._mounted){this._savedState=state;this.setAttribute('state',state);return true;}return this._controller.setState(state);}
    react(kind='poke'){return this._controller?.react(kind)||false;}
    setProgress(value){if(!Number.isFinite(value))throw new TypeError('Progress must be a finite number');this._progress=Math.max(0,Math.min(1,value));this.shadowRoot?.querySelector('.meter')?.setAttribute('stroke-dashoffset',String(942.478*(1-this._progress)));}
    get state(){return this._state;}get baseState(){return this._controller?.baseState||'idle';}get progress(){return this._progress||0;}
    pause(){this._paused=true;this._sync?.();}play(){this._paused=false;this._sync?.();}
    disconnectedCallback(){
      this._savedState=this.baseState;this._controller?.destroy();this._observer?.disconnect();cancelAnimationFrame(this._raf);this._raf=0;
      document.removeEventListener('visibilitychange',this._sync);this._media?.removeEventListener('change',this._sync);
      document.removeEventListener('pointermove',this._pointer);document.removeEventListener('pointerleave',this._resetGaze);
      this.removeEventListener('pointerdown',this._pointer);this.removeEventListener('pointerup',this._resetGaze);this.removeEventListener('click',this._tap);this.removeEventListener('keydown',this._key);
      clearTimeout(this._cleanup);this._animations?.forEach(a=>a?.destroy());this._mounted=false;this.shadowRoot?.replaceChildren();
    }
  }
  customElements.define('grok-bot',GrokBot);
})();
