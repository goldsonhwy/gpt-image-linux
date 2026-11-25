/**
 * Full-page (section) scroll controller, modelled on long.huangse.de's
 * home-fullpage-v1: while enabled, the document is locked and the host
 * (#main-content) becomes a fixed-height paged scroller; each `.fp-page`
 * child fills exactly one host viewport and scrolls its own content.
 * Wheel / touch / keyboard first scroll the *active* page (or the inner
 * scrollable element under the pointer, left to native behaviour) and, once
 * that is exhausted, glide the host to the neighbouring page.
 *
 * Enabled by adding `fp-enabled` to <html> (handled inside). All listeners
 * are no-ops until enable() so the same controller can serve agent mode
 * (off) and studio mode (on) without re-creation.
 */
export interface FullPageController {
  enable(): void;
  disable(): void;
  goPage(next: number, animate?: boolean): void;
  destroy(): void;
}

export function createFullPageController(host: HTMLElement, onPage?: (index: number) => void): FullPageController {
  let index = 0;
  let lockedUntil = 0;
  let lastWheel = 0;
  let wheelSum = 0;
  let touch: { x: number; y: number; scrollTop: number; handled: boolean } | null = null;
  let resizeTimer: ReturnType<typeof setTimeout> | undefined;
  let enabled = false;
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  // The paged layout only exists on desktop; on smaller viewports every
  // handler stays out of the way so native document scrolling keeps working.
  const desktop = window.matchMedia('(min-width: 1024px)');

  function activePages(): HTMLElement[] {
    const list = Array.from(host.querySelectorAll<HTMLElement>(':scope > .fp-page'));
    return list.length >= 2 ? list : [];
  }

  function canScroll(panel: HTMLElement, dir: number): boolean {
    return dir > 0
      ? panel.scrollTop + panel.clientHeight < panel.scrollHeight - 3
      : panel.scrollTop > 3;
  }

  // Deepest scrollable element under `origin` (excluding the page itself)
  // that can still scroll in `dir`. When one exists, native scrolling should
  // keep owning the gesture and we must not swallow it.
  function innerScrollable(origin: Element | null, limit: HTMLElement, dir: number): HTMLElement | null {
    let el = origin;
    while (el && el !== limit && limit.contains(el)) {
      const style = getComputedStyle(el);
      const oy = style.overflowY;
      if ((oy === 'auto' || oy === 'scroll') && el.scrollHeight > el.clientHeight + 1) {
        const can = dir > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - 1 : el.scrollTop > 1;
        if (can) return el;
      }
      el = el.parentElement;
    }
    return null;
  }

  function go(next: number, animate = true): void {
    const list = activePages();
    if (!list.length) return;
    const target = Math.max(0, Math.min(list.length - 1, next));
    const changed = target !== index;
    index = target;
    host.dataset.currentPage = String(index);
    lockedUntil = performance.now() + (animate && !reduced.matches ? 650 : 80);
    host.scrollTo({
      top: list[index].offsetTop,
      behavior: animate && !reduced.matches ? 'smooth' : 'instant'
    });
    if (changed) onPage?.(index);
  }

  // While a modal dialog is open, gestures stay with the dialog (its own
  // scroll / Escape / Tab trap) instead of turning the page underneath it.
  function modalOpen(): boolean {
    return Boolean(document.querySelector('[aria-modal="true"][role="dialog"]:not([hidden])'));
  }

  function onWheel(e: WheelEvent): void {
    if (!enabled || !desktop.matches || modalOpen() || e.ctrlKey || Math.abs(e.deltaX) > Math.abs(e.deltaY) || !e.deltaY) return;
    const list = activePages();
    if (!list.length) return;
    const panel = list[index];
    const dir = Math.sign(e.deltaY);
    // Let inner scrollers (prompt textarea, dropdown lists, ...) keep their
    // native wheel behaviour while they can still scroll in that direction.
    if (innerScrollable(e.target instanceof Element ? e.target : null, panel, dir)) return;
    e.preventDefault();
    const now = performance.now();
    const gap = now - lastWheel;
    lastWheel = now;
    if (now < lockedUntil) {
      wheelSum = 0;
      return;
    }
    // Ignore a long trackpad gesture's momentum after one transition.
    if (gap < 150 && host.dataset.gestureDone === 'true') return;
    if (gap >= 150) {
      host.dataset.gestureDone = 'false';
      wheelSum = 0;
    }
    if (canScroll(panel, dir)) {
      panel.scrollBy({ top: e.deltaY * (e.deltaMode === 1 ? 20 : 1), behavior: 'instant' });
      return;
    }
    if (wheelSum && Math.sign(wheelSum) !== dir) wheelSum = 0;
    wheelSum += e.deltaY * (e.deltaMode === 1 ? 20 : 1);
    if (Math.abs(wheelSum) < 16) return;
    host.dataset.gestureDone = 'true';
    wheelSum = 0;
    go(index + dir);
  }

  function onTouchStart(e: TouchEvent): void {
    if (!enabled || !desktop.matches || e.touches.length !== 1) {
      touch = null;
      return;
    }
    const t = e.touches[0];
    const list = activePages();
    touch = { x: t.clientX, y: t.clientY, scrollTop: list[index]?.scrollTop ?? 0, handled: false };
  }

  function onTouchMove(e: TouchEvent): void {
    if (!touch || !desktop.matches || e.touches.length !== 1) return;
    const dx = e.touches[0].clientX - touch.x;
    const dy = e.touches[0].clientY - touch.y;
    if (Math.abs(dy) < 10 || Math.abs(dx) > Math.abs(dy)) return;
    if (performance.now() < lockedUntil) {
      e.preventDefault();
      touch.handled = true;
      return;
    }
    const list = activePages();
    if (!list.length) return;
    const panel = list[index];
    const dir = dy < 0 ? 1 : -1;
    const under = document.elementFromPoint(e.touches[0].clientX, e.touches[0].clientY);
    // Native scrolling owns gestures that can still scroll the page or an
    // inner element (e.g. the prompt textarea); only a dead-stop becomes
    // a page-turn candidate.
    if (canScroll(panel, dir) || innerScrollable(under, panel, dir)) return;
    e.preventDefault();
    touch.handled = true;
  }

  function onTouchEnd(e: TouchEvent): void {
    if (!touch) return;
    const t = touch;
    touch = null;
    const end = e.changedTouches[0];
    const dy = end.clientY - t.y;
    const dx = end.clientX - t.x;
    if (performance.now() < lockedUntil || Math.abs(dy) < 45 || Math.abs(dy) < Math.abs(dx) * 1.3) return;
    const list = activePages();
    if (!list.length) return;
    // A gesture that scrolled long content must not also turn the page.
    if (Math.abs(list[index].scrollTop - t.scrollTop) > 5) return;
    const dir = dy < 0 ? 1 : -1;
    if (!canScroll(list[index], dir)) go(index + dir);
  }

  function onKeydown(e: KeyboardEvent): void {
    if (!enabled || !desktop.matches || modalOpen() || e.altKey || e.ctrlKey || e.metaKey) return;
    const target = e.target instanceof HTMLElement ? e.target : null;
    if (target?.closest('input, textarea, select, [contenteditable=true]')) return;
    const key = e.key;
    if (!['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '].includes(key)) return;
    if (key === ' ' && target?.closest('a, button')) return;
    e.preventDefault();
    if (performance.now() < lockedUntil) return;
    const list = activePages();
    if (!list.length) return;
    if (key === 'Home') {
      go(0);
      return;
    }
    if (key === 'End') {
      go(list.length - 1);
      return;
    }
    const dir = ['ArrowUp', 'PageUp'].includes(key) || (key === ' ' && e.shiftKey) ? -1 : 1;
    if (canScroll(list[index], dir)) {
      list[index].scrollBy({ top: dir * list[index].clientHeight * 0.75, behavior: 'smooth' });
      return;
    }
    go(index + dir);
  }

  function onResize(): void {
    if (!enabled) return;
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => go(index, false), 100);
  }

  // Keep the page index in sync when something else scrolls the host
  // (e.g. scrollIntoView on the preview panel), outside of our own glides.
  function onScroll(): void {
    if (!enabled || performance.now() < lockedUntil) return;
    const list = activePages();
    if (!list.length) return;
    const top = host.scrollTop;
    let best = 0;
    let bestDist = Number.POSITIVE_INFINITY;
    list.forEach((page, i) => {
      const d = Math.abs(page.offsetTop - top);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    });
    if (best !== index) {
      index = best;
      host.dataset.currentPage = String(index);
      onPage?.(index);
    }
  }

  function onFocusIn(e: FocusEvent): void {
    if (!enabled) return;
    const list = activePages();
    const n = list.findIndex((p) => p.contains(e.target as Node));
    if (n >= 0 && n !== index) go(n, false);
  }

  host.addEventListener('wheel', onWheel, { passive: false });
  host.addEventListener('touchstart', onTouchStart, { passive: true });
  host.addEventListener('touchmove', onTouchMove, { passive: false });
  host.addEventListener('touchend', onTouchEnd, { passive: true });
  host.addEventListener('touchcancel', () => (touch = null), { passive: true });
  host.addEventListener('scroll', onScroll, { passive: true });
  document.addEventListener('keydown', onKeydown);
  window.addEventListener('resize', onResize);
  host.addEventListener('focusin', onFocusIn);
  const observer = new ResizeObserver(onResize);
  observer.observe(host);

  return {
    enable() {
      enabled = true;
      index = 0;
      document.documentElement.classList.add('fp-enabled');
      go(0, false);
      onPage?.(0);
    },
    disable() {
      enabled = false;
      document.documentElement.classList.remove('fp-enabled');
    },
    goPage(next: number, animate = true) {
      if (enabled) go(next, animate);
    },
    destroy() {
      observer.disconnect();
      clearTimeout(resizeTimer);
      host.removeEventListener('wheel', onWheel);
      host.removeEventListener('touchstart', onTouchStart);
      host.removeEventListener('touchmove', onTouchMove);
      host.removeEventListener('touchend', onTouchEnd);
      host.removeEventListener('scroll', onScroll);
      document.removeEventListener('keydown', onKeydown);
      window.removeEventListener('resize', onResize);
      host.removeEventListener('focusin', onFocusIn);
      this.disable();
    }
  };
}
