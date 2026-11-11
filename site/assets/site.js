// bterm site. No framework: reveals, the theme picker, copy buttons and a
// version check against the latest GitHub release.
document.documentElement.classList.add('js');

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

document.addEventListener('DOMContentLoaded', () => {
  // Header tightens once the page scrolls
  const onScroll = () => document.body.classList.toggle('scrolled', scrollY > 24);
  onScroll();
  addEventListener('scroll', onScroll, { passive: true });

  // Reveal on scroll
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }
  }, { rootMargin: '0px 0px -8% 0px' });
  $$('[data-reveal]').forEach((el) => io.observe(el));

  // Current section in the nav
  const links = $$('.nav a[href^="#"]');
  const spy = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      links.forEach((a) => a.classList.toggle('active', a.getAttribute('href') === '#' + e.target.id));
    }
  }, { rootMargin: '-45% 0px -50% 0px' });
  links.forEach((a) => { const s = $(a.getAttribute('href')); if (s) spy.observe(s); });

  initThemes();
  initCopy();
  initFootMark();
  $$('[data-year]').forEach((el) => { el.textContent = new Date().getFullYear(); });
  checkVersion();
});

// The screenshot above the fold, in each of bterm's five themes
function initThemes() {
  const win = $('.window');
  const buttons = $$('.seg [data-theme]');
  if (!win || !buttons.length) return;
  const shots = { vercel: $('.shot', win) };
  const alt = shots.vercel.getAttribute('alt');

  const load = (id) => {
    if (shots[id]) return shots[id];
    const img = new Image();
    img.className = 'shot';
    img.src = `assets/shots/theme-${id}.png`;
    img.width = 2560; img.height = 1560;
    img.alt = '';
    img.decoding = 'async';
    win.appendChild(img);
    return (shots[id] = img);
  };

  const pick = (btn) => {
    const id = btn.dataset.theme;
    buttons.forEach((b) => b.setAttribute('aria-checked', String(b === btn)));
    const next = load(id);
    const show = () => {
      Object.values(shots).forEach((img) => { img.classList.toggle('is-on', img === next); img.alt = img === next ? alt : ''; });
    };
    next.complete ? show() : next.addEventListener('load', show, { once: true });
  };

  buttons.forEach((b, i) => {
    b.addEventListener('click', () => pick(b));
    b.addEventListener('pointerenter', () => load(b.dataset.theme), { once: true });
    b.addEventListener('keydown', (e) => {
      const d = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      const n = buttons[(i + d + buttons.length) % buttons.length];
      n.focus();
      pick(n);
    });
    b.tabIndex = i === 0 ? 0 : -1;
  });
  // Keep the roving tabindex on the checked one
  $('.seg').addEventListener('click', () => buttons.forEach((b) => { b.tabIndex = b.getAttribute('aria-checked') === 'true' ? 0 : -1; }));
}

function initCopy() {
  let timer;
  $$('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(btn.dataset.copy);
      } catch {
        const t = document.createElement('textarea');
        t.value = btn.dataset.copy;
        document.body.appendChild(t);
        t.select();
        document.execCommand('copy');
        t.remove();
      }
      btn.classList.add('copied');
      clearTimeout(btn._t);
      btn._t = setTimeout(() => btn.classList.remove('copied'), 1800);
      const toast = $('#toast');
      toast.textContent = 'Copied. Paste it into your terminal.';
      toast.classList.add('show');
      clearTimeout(timer);
      timer = setTimeout(() => toast.classList.remove('show'), 2200);
    });
  });
}

// The icon in the footer rises as you reach the bottom of the page
function initFootMark() {
  const mark = $('.foot-mark');
  if (!mark || reduced) return;
  let ticking = false;
  const update = () => {
    ticking = false;
    const r = mark.getBoundingClientRect();
    const p = Math.min(1, Math.max(0, (innerHeight - r.top) / (r.height + 120)));
    mark.style.setProperty('--rise', `${(1 - p) * 45 + 12}%`);
  };
  addEventListener('scroll', () => { if (!ticking) { ticking = true; requestAnimationFrame(update); } }, { passive: true });
  update();
}

// Show the real latest version once GitHub answers. The download links point at
// releases/latest already, so this is only the label.
async function checkVersion() {
  try {
    const r = await fetch('https://api.github.com/repos/beckettclarke/bterm/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' },
    });
    if (!r.ok) return;
    const { tag_name: tag } = await r.json();
    if (tag) $$('[data-version]').forEach((el) => { el.textContent = tag; });
  } catch { /* offline or rate limited: keep the built-in label */ }
}
