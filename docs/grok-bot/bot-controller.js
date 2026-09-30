/* Business state and playful expressions are intentionally controlled separately. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else if (typeof define === 'function' && define.amd) define([], factory);
  else root.BotController = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const STATES = new Set([
    'idle', 'listening', 'thinking', 'speaking', 'upload', 'error',
    'happy', 'greeting', 'curious'
  ]);
  const ONE_SHOTS = { happy: 2200, greeting: 1600 };
  const POKES = [
    { state: 'curious', duration: 1000 },
    { state: 'annoyed', duration: 1400 },
    { state: 'dizzy', duration: 2000 }
  ];

  class BotController {
    constructor(options = {}) {
      if (options.onChange !== undefined && typeof options.onChange !== 'function') {
        throw new TypeError('onChange must be a function');
      }
      this._onChange = options.onChange || function () {};
      this._setTimer = options.setTimer || ((callback, delay) => setTimeout(callback, delay));
      this._clearTimer = options.clearTimer || (id => clearTimeout(id));
      this._state = 'idle';
      this._baseState = 'idle';
      this._temporary = false;
      this._destroyed = false;
      this._reactionTimer = null;
      this._pokeTimer = null;
      this._reactionRevision = 0;
      this._pokeRevision = 0;
      this._pokeCount = 0;
      this._show('idle', false);
    }

    get state() { return this._state; }
    get baseState() { return this._baseState; }

    // Explicit business changes always supersede an expression and its callbacks.
    // happy/greeting are one-shot commands returning to idle. To preserve ongoing
    // work while celebrating or greeting, use react('celebrate' / 'greet').
    setState(state) {
      if (this._destroyed) return false;
      if (!STATES.has(state)) throw new RangeError('Unknown bot state: ' + state);
      this._cancelReaction();
      this._resetPokes();
      const duration = ONE_SHOTS[state];
      this._baseState = duration ? 'idle' : state;
      if (duration) this._startTemporary(state, duration);
      else this._show(state, false);
      return true;
    }

    react(kind) {
      if (this._destroyed) return false;
      if (!['poke', 'greet', 'celebrate'].includes(kind)) {
        throw new RangeError('Unknown bot reaction: ' + kind);
      }
      // An error remains visible until the application explicitly changes it.
      if (this._baseState === 'error') return false;

      if (kind === 'poke') {
        if (this._pokeCount === 0) {
          const revision = ++this._pokeRevision;
          // A burst is measured from its first poke, not extended indefinitely.
          this._pokeTimer = this._setTimer(() => {
            if (this._destroyed || revision !== this._pokeRevision) return;
            this._pokeTimer = null;
            this._pokeCount = 0;
          }, 3000);
        }
        const expression = POKES[Math.min(this._pokeCount++, POKES.length - 1)];
        this._startTemporary(expression.state, expression.duration);
      } else {
        this._resetPokes();
        const state = kind === 'greet' ? 'greeting' : 'happy';
        this._startTemporary(state, ONE_SHOTS[state]);
      }
      return true;
    }

    _show(state, temporary) {
      if (this._destroyed) return;
      this._state = state;
      this._temporary = temporary;
      this._onChange(state, { baseState: this._baseState, temporary });
    }

    _startTemporary(state, duration) {
      this._cancelReaction();
      const revision = this._reactionRevision;
      // Schedule first so a reentrant onChange can cancel this exact operation.
      this._reactionTimer = this._setTimer(() => {
        if (this._destroyed || revision !== this._reactionRevision) return;
        this._reactionTimer = null;
        this._show(this._baseState, false);
      }, duration);
      this._show(state, true);
    }

    _cancelReaction() {
      ++this._reactionRevision;
      if (this._reactionTimer !== null) this._clearTimer(this._reactionTimer);
      this._reactionTimer = null;
    }

    _resetPokes() {
      ++this._pokeRevision;
      if (this._pokeTimer !== null) this._clearTimer(this._pokeTimer);
      this._pokeTimer = null;
      this._pokeCount = 0;
    }

    destroy() {
      if (this._destroyed) return;
      this._destroyed = true;
      this._cancelReaction();
      this._resetPokes();
      this._onChange = function () {};
    }
  }

  return BotController;
});
