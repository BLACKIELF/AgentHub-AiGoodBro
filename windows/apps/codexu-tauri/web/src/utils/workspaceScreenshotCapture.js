(() => {
  const key = '__aigoodbroWorkspaceScreenshotCapture';
  if (window[key]) return;

  const restore = () => {
    const state = window[key]?.state;
    if (!state) {
      document.getElementById('native-workspace-screenshot-fixture')?.remove();
      delete window.__AIGOODBRO_NATIVE_WORKSPACE_SCREENSHOT_FIXTURE__;
      return true;
    }
    window[key].state = null;
    state.styleNode.remove();
    state.testFixture?.remove();
    state.shell.removeAttribute('data-aigoodbro-screenshot-capture');
    delete window.__AIGOODBRO_NATIVE_WORKSPACE_SCREENSHOT_FIXTURE__;
    for (const { element, left, top } of state.scroll) {
      element.scrollLeft = left;
      element.scrollTop = top;
    }
    window.scrollTo(state.windowLeft, state.windowTop);
    return true;
  };

  const prepare = () => {
    if (window[key].state) return { ok: false, error: 'capture_busy' };
    const root = document.getElementById('root');
    const shell = document.querySelector('.workspace-shell');
    const main = document.getElementById('windows-home');
    if (!root || !shell || !main || !shell.contains(main)) {
      return { ok: false, error: 'workspace_unavailable' };
    }
    if (shell.hasAttribute('data-aigoodbro-screenshot-capture')) {
      return { ok: false, error: 'capture_busy' };
    }
    if (document.querySelector('[role="dialog"]:not([hidden]), [aria-modal="true"]:not([hidden])')) {
      return { ok: false, error: 'dialog_open' };
    }

    const scrollSurfaces = [...main.querySelectorAll('.home-resizable-viewport, .token-monitor-source-grid')]
      .filter(element => !element.closest('[hidden]') && element.getClientRects().length > 0);
    const scrollElements = new Set([document.scrollingElement, main, ...scrollSurfaces].filter(Boolean));
    for (const element of main.querySelectorAll('*')) {
      if (element.closest('[hidden]') || element.getClientRects().length === 0) continue;
      const style = getComputedStyle(element);
      const scrollable = ['auto', 'scroll', 'overlay'].includes(style.overflowY)
        || ['auto', 'scroll', 'overlay'].includes(style.overflowX);
      if (scrollable && (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth)) {
        scrollElements.add(element);
      }
    }
    const state = {
      scroll: [...scrollElements].map(element => ({ element, left: element.scrollLeft, top: element.scrollTop })),
      shell,
      styleNode: document.createElement('style'),
      testFixture: null,
      windowLeft: window.scrollX,
      windowTop: window.scrollY,
    };
    state.styleNode.textContent = `
      .workspace-shell[data-aigoodbro-screenshot-capture="active"] {
        height: auto !important; min-height: 100vh !important; overflow: visible !important;
      }
      .workspace-shell[data-aigoodbro-screenshot-capture="active"] #windows-home {
        flex: 0 0 auto !important; height: auto !important; min-height: 0 !important;
        max-height: none !important; overflow: visible !important; scroll-behavior: auto !important;
      }
      .workspace-shell[data-aigoodbro-screenshot-capture="active"] #windows-home .home-resizable-viewport,
      .workspace-shell[data-aigoodbro-screenshot-capture="active"] #windows-home .token-monitor-source-grid {
        height: auto !important; max-height: none !important; overflow: visible !important;
        scroll-behavior: auto !important;
      }
    `;
    window[key].state = state;

    try {
      if (window.__AIGOODBRO_NATIVE_WORKSPACE_SCREENSHOT_FIXTURE__ === true) {
        const fixture = document.createElement('section');
        fixture.id = 'native-workspace-screenshot-fixture';
        fixture.setAttribute('role', 'note');
        fixture.setAttribute('aria-label', 'Native workspace screenshot capture fixture');
        fixture.textContent = 'U03 native screenshot capture fixture';
        fixture.style.cssText = [
          'box-sizing:border-box', 'display:flex', 'align-items:center', 'justify-content:center',
          'width:100%', 'height:960px', 'min-height:960px', 'border:8px solid #00e5ff',
          'background:#ff2d6f', 'color:#ffffff', 'font:600 20px sans-serif',
        ].join(';');
        state.testFixture = fixture;
        main.append(fixture);
      }
      shell.setAttribute('data-aigoodbro-screenshot-capture', 'active');
      document.head.append(state.styleNode);
      main.scrollTop = 0;
      for (const surface of scrollSurfaces) surface.scrollTop = 0;
      window.scrollTo(0, 0);

      return {
        ok: true,
        width: Math.ceil(document.documentElement.clientWidth),
        height: Math.ceil(Math.max(
          document.documentElement.scrollHeight,
          document.body.scrollHeight,
          root.scrollHeight,
          shell.scrollHeight,
        )),
      };
    } catch {
      restore();
      return { ok: false, error: 'capture_prepare_failed' };
    }
  };

  window[key] = { prepare, restore, state: null };
})();
