// Header state, scroll reveals, the outage demo, screenshot tabs, the kill switch turntable and the docs contents.

(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');

  const top = document.querySelector('.top');
  if (top) {
    const onScroll = () => top.classList.toggle('scrolled', scrollY > 8);
    addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }

  // Packets along the pipes: SMIL keeps running under reduced motion, so drop it there.
  const pipes = document.querySelector('[data-pipes]');
  if (pipes && reduced.matches) pipes.querySelector('.packets')?.remove();

  // ---------- reveals ----------

  // Only blocks that start below the fold fade in; everything is visible without JS.
  if ('IntersectionObserver' in window && !reduced.matches) {
    const io = new IntersectionObserver(entries => {
      for (const e of entries) {
        if (e.isIntersecting) { e.target.classList.remove('pre'); io.unobserve(e.target); }
      }
    }, { rootMargin: '0px 0px -8% 0px' });
    document.querySelectorAll('.reveal').forEach(el => {
      if (el.getBoundingClientRect().top < innerHeight) return;
      el.classList.add('pre');
      io.observe(el);
    });
  }

  // ---------- when a route goes down ----------

  const outage = document.querySelector('[data-outage]');
  if (outage) {
    const RESULTS = {
      block: 'Slack gets no network until WireGuard “Work” is back. Nothing leaves through another route.',
      default: 'Slack goes wherever macOS sends traffic now. With your VPN’s kill switch on, that means through the VPN or blocked.',
      fallback: 'Slack moves to the fallback, Amnezia VPN. If that route is down too, Slack is blocked.',
    };
    const result = outage.querySelector('[data-result]');
    const buttons = outage.querySelectorAll('[data-mode]');
    const lanes = outage.querySelectorAll('[data-lane]');
    buttons.forEach(btn => btn.addEventListener('click', () => {
      const mode = btn.dataset.mode;
      buttons.forEach(b => b.setAttribute('aria-pressed', String(b === btn)));
      lanes.forEach(l => l.classList.toggle('off', l.dataset.lane !== mode));
      result.textContent = RESULTS[mode];
    }));
  }

  // ---------- screenshot tabs ----------

  const tablist = document.querySelector('[data-tabs]');
  if (tablist) {
    const tabs = [...tablist.querySelectorAll('[role="tab"]')];
    const captions = document.querySelectorAll('[data-captions] [data-for]');
    const select = (tab, focus) => {
      tabs.forEach(t => {
        const on = t === tab;
        t.setAttribute('aria-selected', String(on));
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
      });
      captions.forEach(c => { c.hidden = c.dataset.for !== tab.getAttribute('aria-controls'); });
      if (focus) tab.focus();
    };
    tabs.forEach((tab, i) => {
      tab.addEventListener('click', () => select(tab));
      tab.addEventListener('keydown', e => {
        const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
        if (step) { e.preventDefault(); select(tabs[(i + step + tabs.length) % tabs.length], true); }
        if (e.key === 'Home') { e.preventDefault(); select(tabs[0], true); }
        if (e.key === 'End') { e.preventDefault(); select(tabs[tabs.length - 1], true); }
      });
    });
  }

  // ---------- kill switch turntable: pre-rendered frames that turn toward the pointer ----------

  // Touch screens and reduced motion keep the single front render.
  const stage = document.querySelector('[data-turntable]');
  const finePointer = matchMedia('(hover: hover) and (pointer: fine)').matches;
  if (stage && finePointer && 'IntersectionObserver' in window && !reduced.matches) {
    const frames = Number(stage.dataset.frames);
    const io = new IntersectionObserver(entries => {
      if (!entries.some(e => e.isIntersecting)) return;
      io.disconnect();
      const sprite = new Image();
      sprite.src = stage.dataset.turntable;
      sprite.decode().then(() => {
        const view = document.createElement('div');
        view.className = 'turntable';
        view.setAttribute('aria-hidden', 'true');
        view.style.backgroundImage = `url("${sprite.src}")`;
        view.style.backgroundSize = `${frames * 100}% 100%`;
        stage.append(view);
        let current = -1;
        const show = i => {
          if (i === current) return;
          current = i;
          view.style.backgroundPosition = `${(i / (frames - 1)) * 100}% 0`;
        };
        show((frames - 1) / 2);
        stage.classList.add('live');
        // The band is wide, so map the pointer across the whole section, centre = front view.
        const band = stage.closest('.band') || stage;
        addEventListener('pointermove', e => {
          const r = band.getBoundingClientRect();
          if (e.clientY < r.top - 200 || e.clientY > r.bottom + 200) return;
          const t = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
          show(Math.round(t * (frames - 1)));
        }, { passive: true });
      }).catch(() => {});
    }, { rootMargin: '300px 0px' });
    io.observe(stage);
  }

  // ---------- docs contents ----------

  const toc = document.querySelector('[data-toc]');
  if (toc && 'IntersectionObserver' in window) {
    const links = new Map([...toc.querySelectorAll('a[href^="#"]')].map(a => [a.getAttribute('href').slice(1), a]));
    const visible = new Set();
    const io = new IntersectionObserver(entries => {
      for (const e of entries) e.isIntersecting ? visible.add(e.target.id) : visible.delete(e.target.id);
      const first = [...links.keys()].find(id => visible.has(id));
      if (!first) return;
      links.forEach((a, id) => {
        a.classList.toggle('active', id === first);
        if (id === first) a.setAttribute('aria-current', 'location'); else a.removeAttribute('aria-current');
      });
    }, { rootMargin: '-80px 0px -55% 0px' });
    links.forEach((_, id) => { const s = document.getElementById(id); if (s) io.observe(s); });
  }

  // Close the mobile contents after a jump.
  document.querySelectorAll('.toc-mobile a').forEach(a => a.addEventListener('click', () => a.closest('details').open = false));
})();
