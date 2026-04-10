// Injected via Runtime.evaluate after each Page.frameNavigated.
// Wraps history.pushState/replaceState to emit custom events.

(function clmuxHistoryHook() {
  if (window.__clmux_history_hook_installed) return;
  window.__clmux_history_hook_installed = true;

  const origPush = history.pushState;
  const origReplace = history.replaceState;

  history.pushState = function (...args) {
    const result = origPush.apply(this, args);
    window.dispatchEvent(new CustomEvent('clmux:navigate', { detail: { type: 'push', url: location.href } }));
    return result;
  };

  history.replaceState = function (...args) {
    const result = origReplace.apply(this, args);
    window.dispatchEvent(new CustomEvent('clmux:navigate', { detail: { type: 'replace', url: location.href } }));
    return result;
  };

  window.addEventListener('popstate', () => {
    window.dispatchEvent(new CustomEvent('clmux:navigate', { detail: { type: 'pop', url: location.href } }));
  });
})();
