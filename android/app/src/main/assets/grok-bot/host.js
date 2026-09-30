/* App-owned host. One-way evaluated state updates; no native JavaScript bridge. */
(() => {
  'use strict';
  const bot = document.getElementById('assistant');
  const states = new Set(['idle', 'listening', 'thinking', 'speaking', 'error', 'happy', 'greeting', 'curious']);
  let current = null;
  let interactive = true;
  let reducedMotion = false;
  let running = false;

  // This isolated document contains only the bot. Blocking capture also stops its
  // document-level gaze listener when the native caller uses a decorative avatar.
  const filterInteraction = event => {
    if (!interactive) event.stopImmediatePropagation();
  };
  for (const event of ['pointermove', 'pointerdown', 'pointerup', 'pointerleave', 'click', 'keydown']) {
    document.addEventListener(event, filterInteraction, { capture: true, passive: true });
  }
  const syncAccessibility = () => {
    bot.setAttribute('role', interactive ? 'button' : 'img');
    bot.tabIndex = interactive ? 0 : -1;
    const label = bot.getAttribute('aria-label') || '灵动伙伴';
    if (!interactive) bot.setAttribute('aria-label', label.replace('；轻点互动', ''));
    else if (!label.includes('；轻点互动')) bot.setAttribute('aria-label', label + '；轻点互动');
  };
  bot.addEventListener('statechange', syncAccessibility);
  bot.pause();

  window.WorkbenchBot = Object.freeze({
    update(value) {
      if (!value || typeof value !== 'object') return;
      interactive = value.interactive !== false;
      const nextReducedMotion = value.reducedMotion === true;
      if (nextReducedMotion !== reducedMotion) {
        reducedMotion = nextReducedMotion;
        bot.setReducedMotion(reducedMotion);
      }
      const next = states.has(value.state) ? value.state : 'idle';
      // Input state is kept separately from bot.baseState: one-shot happy returns
      // to idle internally and must not replay on an unrelated Compose update.
      if (next !== current) {
        current = next;
        bot.setState(next);
      }
      syncAccessibility();
      const nextRunning = value.running === true;
      if (nextRunning !== running) {
        running = nextRunning;
        if (running) bot.play();
        else bot.pause();
      }
    },
    dispose() {
      bot.pause();
      bot.remove();
      for (const event of ['pointermove', 'pointerdown', 'pointerup', 'pointerleave', 'click', 'keydown']) {
        document.removeEventListener(event, filterInteraction, true);
      }
      delete window.WorkbenchBot;
    }
  });
})();
