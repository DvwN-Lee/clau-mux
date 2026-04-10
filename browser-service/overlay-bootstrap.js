// Injected into every new document via Page.addScriptToEvaluateOnNewDocument.
// Runs in browser page context, NOT Node.js.
// Bindings: clmuxInspectComment (called when user submits comment)

(function clmuxBootstrap() {
  if (window.__clmux_bootstrap_installed) return;
  window.__clmux_bootstrap_installed = true;

  window.__clmux_inspect_active = false;
  window.__clmux_subscriber_label = '(none)';

  function ensureLabel() {
    let label = document.getElementById('__clmux_label');
    if (!label) {
      label = document.createElement('div');
      label.id = '__clmux_label';
      label.style.cssText = [
        'position: fixed', 'top: 10px', 'right: 10px', 'z-index: 2147483647',
        'background: rgba(0,0,0,0.85)', 'color: white', 'padding: 6px 12px',
        'font: 12px system-ui, sans-serif', 'border-radius: 4px',
        'pointer-events: none', 'display: none',
      ].join(';');
      (document.body || document.documentElement).appendChild(label);
    }
    return label;
  }

  function updateLabel(subscriber) {
    window.__clmux_subscriber_label = subscriber || '(none)';
    const label = ensureLabel();
    if (window.__clmux_inspect_active) {
      label.textContent = 'clmux inspect \u2192 ' + window.__clmux_subscriber_label;
      label.style.display = 'block';
    } else {
      label.style.display = 'none';
    }
  }

  // Build comment popup using DOM methods (no innerHTML — XSS-safe)
  function buildCommentPopup() {
    const existing = document.getElementById('__clmux_comment_popup');
    if (existing) existing.remove();

    const popup = document.createElement('div');
    popup.id = '__clmux_comment_popup';
    popup.style.cssText = [
      'position: fixed', 'top: 50%', 'left: 50%',
      'transform: translate(-50%, -50%)', 'z-index: 2147483647',
      'background: white', 'border: 2px solid #4285f4', 'border-radius: 8px',
      'padding: 16px', 'box-shadow: 0 4px 20px rgba(0,0,0,0.3)',
      'font: 14px system-ui, sans-serif', 'min-width: 320px',
    ].join(';');

    const title = document.createElement('div');
    title.textContent = 'clmux inspect \u2014 \uCF54\uBA58\uD2B8 (\uC120\uD0DD)';
    title.style.cssText = 'margin-bottom: 8px; font-weight: bold; color: #333';
    popup.appendChild(title);

    const input = document.createElement('input');
    input.type = 'text';
    input.id = '__clmux_comment_input';
    input.placeholder = '\uC608: padding\uC774 \uC774\uC0C1\uD574 / \uC0C9\uC0C1\uC774 \uD14C\uB9C8\uC640 \uC548 \uB9DE\uC74C';
    input.style.cssText = [
      'width: 100%', 'padding: 8px', 'border: 1px solid #ccc',
      'border-radius: 4px', 'box-sizing: border-box',
    ].join(';');
    popup.appendChild(input);

    const btnRow = document.createElement('div');
    btnRow.style.cssText = 'margin-top: 12px; text-align: right';

    const cancelBtn = document.createElement('button');
    cancelBtn.id = '__clmux_comment_cancel';
    cancelBtn.textContent = '\uCDE8\uC18C';
    cancelBtn.style.cssText = [
      'padding: 6px 12px', 'margin-right: 8px',
      'border: 1px solid #ccc', 'background: white',
      'border-radius: 4px', 'cursor: pointer',
    ].join(';');
    btnRow.appendChild(cancelBtn);

    const submitBtn = document.createElement('button');
    submitBtn.id = '__clmux_comment_submit';
    submitBtn.textContent = '\uC81C\uCD9C';
    submitBtn.style.cssText = [
      'padding: 6px 12px', 'background: #4285f4', 'color: white',
      'border: none', 'border-radius: 4px', 'cursor: pointer',
    ].join(';');
    btnRow.appendChild(submitBtn);

    popup.appendChild(btnRow);
    document.body.appendChild(popup);
    return { popup, input, submitBtn, cancelBtn };
  }

  function showCommentPopup(onSubmit) {
    const { popup, input, submitBtn, cancelBtn } = buildCommentPopup();
    input.focus();

    const doSubmit = () => {
      const value = input.value || '';
      popup.remove();
      onSubmit(value);
    };
    submitBtn.addEventListener('click', doSubmit);
    cancelBtn.addEventListener('click', () => { popup.remove(); onSubmit(''); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); doSubmit(); }
      if (e.key === 'Escape') { popup.remove(); onSubmit(''); }
    });
  }

  window.__clmux_set_active = function (active, subscriber) {
    window.__clmux_inspect_active = !!active;
    updateLabel(subscriber);
  };

  window.__clmux_prompt_comment = function () {
    return new Promise((resolve) => {
      showCommentPopup((comment) => {
        if (typeof window.clmuxInspectComment === 'function') {
          window.clmuxInspectComment(comment);
        }
        resolve(comment);
      });
    });
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => ensureLabel());
  } else {
    ensureLabel();
  }
})();
