const menuButton = document.querySelector('.menu-button');
const nav = document.querySelector('.site-nav');
menuButton.addEventListener('click', () => {
  const open = menuButton.getAttribute('aria-expanded') !== 'true';
  menuButton.setAttribute('aria-expanded', String(open));
  menuButton.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  nav.classList.toggle('is-open', open);
});
nav.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => {
  menuButton.setAttribute('aria-expanded', 'false');
  menuButton.setAttribute('aria-label', 'Open menu');
  nav.classList.remove('is-open');
}));

const heroVisual = document.querySelector('.hero-visual');
const heroButton = document.querySelector('.hero-dissect-button');
let heroHover = false;
let heroPinned = false;
let heroFocus = false;
let heroSuppressHover = false;
function updateHero() {
  const open = heroHover || heroPinned || heroFocus;
  heroVisual.classList.toggle('is-dissected', open);
  heroButton.setAttribute('aria-pressed', String(heroPinned));
  const label = heroPinned ? 'Reassemble' : heroHover ? 'Keep this view' : matchMedia('(hover: none)').matches ? 'Tap to dissect' : 'Hover to dissect';
  heroButton.innerHTML = `${label} <span aria-hidden="true">✳</span>`;
  heroVisual.setAttribute('aria-label', open ? 'Exploded illustration of the Keepshake band: printed shell, BLE and microphone board, battery compartment, and woven strap' : 'Keepshake wristband illustration. Hover, focus, or tap to see its parts.');
}
heroVisual.addEventListener('pointerenter', (event) => {
  if (!heroSuppressHover && (event.pointerType === 'mouse' || event.pointerType === 'pen')) { heroHover = true; updateHero(); }
});
heroVisual.addEventListener('pointerleave', () => { heroHover = false; heroSuppressHover = false; updateHero(); });
heroVisual.addEventListener('focusin', (event) => {
  if (event.target === heroVisual && heroVisual.matches(':focus-visible')) { heroFocus = true; updateHero(); }
});
heroVisual.addEventListener('focusout', (event) => {
  if (!heroVisual.contains(event.relatedTarget)) { heroFocus = false; updateHero(); }
});
heroVisual.addEventListener('keydown', (event) => {
  if (event.target === heroVisual && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault(); heroPinned = !heroPinned; updateHero();
  }
});
heroButton.addEventListener('click', () => {
  heroPinned = !heroPinned;
  if (!heroPinned) { heroHover = false; heroFocus = false; heroSuppressHover = true; }
  updateHero();
});
updateHero();

const stage = document.querySelector('.dissect-stage');
const dissectButton = document.querySelector('.dissect-toggle');
const stageState = document.querySelector('.stage-state');
const stageHint = document.querySelector('.stage-hint');
let hovering = false;
let pinned = false;
let keyboardFocus = false;
let suppressHover = false;
function updateDissection() {
  const open = hovering || pinned || keyboardFocus;
  stage.classList.toggle('is-dissected', open);
  stageState.textContent = open ? 'INSIDE VIEW / ILLUSTRATED' : 'OUTSIDE VIEW';
  stageHint.innerHTML = pinned ? 'CLICK TO REASSEMBLE <span aria-hidden="true">↗</span>' : open ? 'MOVE AWAY TO REASSEMBLE <span aria-hidden="true">↗</span>' : 'HOVER TO DISSECT <span aria-hidden="true">↗</span>';
  dissectButton.setAttribute('aria-pressed', String(pinned));
  dissectButton.innerHTML = pinned ? 'Reassemble <span aria-hidden="true">−</span>' : hovering ? 'Keep this view <span aria-hidden="true">＋</span>' : 'See inside <span aria-hidden="true">＋</span>';
  stage.setAttribute('aria-label', open ? 'Exploded illustration showing enclosure, nRF52840 board, battery compartment, and woven strap' : 'Assembled Keepshake wristband illustration. Hover, focus, or use the button to see inside.');
}
stage.addEventListener('pointerenter', (event) => {
  if (!suppressHover && (event.pointerType === 'mouse' || event.pointerType === 'pen')) { hovering = true; updateDissection(); }
});
stage.addEventListener('pointerleave', () => { hovering = false; suppressHover = false; updateDissection(); });
stage.addEventListener('focusin', (event) => {
  if (event.target === stage && stage.matches(':focus-visible')) { keyboardFocus = true; updateDissection(); }
});
stage.addEventListener('focusout', (event) => {
  if (!stage.contains(event.relatedTarget)) { keyboardFocus = false; updateDissection(); }
});
stage.addEventListener('keydown', (event) => {
  if (event.target === stage && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault(); pinned = !pinned; updateDissection();
  }
});
dissectButton.addEventListener('click', () => {
  pinned = !pinned;
  if (!pinned) { hovering = false; keyboardFocus = false; suppressHover = true; }
  updateDissection();
});

const screenButtons = [...document.querySelectorAll('[data-screen]')];
const screens = [...document.querySelectorAll('[data-app-screen]')];
const tabIcons = [...document.querySelectorAll('.app-tabbar > span')];
let appScreen = 'today';
let screenTimer;
let interacted = false;
function showScreen(name) {
  appScreen = name;
  screenButtons.forEach((button) => {
    const active = button.dataset.screen === name;
    button.classList.toggle('is-active', active);
    button.setAttribute('aria-pressed', String(active));
  });
  screens.forEach((screen) => {
    const active = screen.dataset.appScreen === name;
    screen.classList.toggle('is-active', active);
    screen.setAttribute('aria-hidden', String(!active));
    screen.inert = !active;
  });
  tabIcons.forEach((icon, index) => icon.classList.toggle('tab-active', index === ({today:0,memory:3,ask:4})[name]));
}
screenButtons.forEach((button) => button.addEventListener('click', () => {
  interacted = true;
  clearInterval(screenTimer);
  showScreen(button.dataset.screen);
}));
showScreen('today');
if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
  const sections = document.querySelectorAll('.prototype-section, .band-section, .memory-section, .ios-section, .closing');
  const reveal = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) { entry.target.classList.add('is-visible'); reveal.unobserve(entry.target); }
    });
  }, { threshold: .08 });
  sections.forEach((section) => { section.classList.add('will-reveal'); reveal.observe(section); });
  const phoneObserver = new IntersectionObserver((entries) => {
    const visible = entries[0]?.isIntersecting;
    clearInterval(screenTimer);
    if (visible && !interacted) {
      screenTimer = setInterval(() => {
        const order = ['today','memory','ask'];
        showScreen(order[(order.indexOf(appScreen) + 1) % order.length]);
      }, 7000);
    }
  }, { threshold: .3 });
  phoneObserver.observe(document.querySelector('.ios-section'));
}
