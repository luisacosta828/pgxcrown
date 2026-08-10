/* ==========================================================================
   Pgxcrown v0.12.0 - Product Showcase & Interactive Mechanics
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  initCodeTabs();
  initCliSimulator();
  initAnimeAnimations();
});

/* --------------------------------------------------------------------------
   1. Live Code Snippets (Showcasing All Pgxcrown Features)
   -------------------------------------------------------------------------- */
const codeSnippets = {
  nim: `<span class="syn-cmt"># 1. High-Performance Extension Procedure in Nim</span>
<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">add_numbers</span>*(a: <span class="syn-type">int32</span>, b: <span class="syn-type">int32</span>): <span class="syn-type">int32</span> =
  <span class="syn-kw">return</span> a + b

<span class="syn-kw">proc</span> <span class="syn-fn">greet_user</span>*(name: <span class="syn-type">string</span>): <span class="syn-type">string</span> =
  <span class="syn-kw">return</span> <span class="syn-str">"Hello from Nim & Postgres, "</span> & name & <span class="syn-str">"!"</span>

<span class="syn-cmt"># Auto-Bound to Native C SQL Bindings at Build Time:</span>
<span class="syn-sql">CREATE OR REPLACE FUNCTION add_numbers(int4, int4) RETURNS int4 as</span>
<span class="syn-sql">'$libdir/my_extension', 'pgx_add_numbers' LANGUAGE c STRICT;</span>`,

  shield: `<span class="syn-cmt"># v0.12.0 Automatic Panic & Exception Shield</span>
<span class="syn-kw">func</span> <span class="syn-fn">pgx_proof_integer_overflow</span>(): <span class="syn-type">Datum</span> <span class="syn-pragma">{.pgv1, trusted.}</span> =
  <span class="syn-kw">try</span>:
    <span class="syn-kw">var</span> a: <span class="syn-type">cint</span> = getInt32(0)
    <span class="syn-kw">var</span> b: <span class="syn-type">cint</span> = getInt32(1)
    <span class="syn-kw">return</span> a + b  <span class="syn-cmt"># OverflowDefect caught cleanly!</span>
  <span class="syn-kw">except</span> <span class="syn-type">Defect</span> <span class="syn-kw">as</span> e:
    <span class="syn-fn">reportError</span>(<span class="syn-str">"Extension Defect ["</span> & $e.name & <span class="syn-str">"]: "</span> & e.msg)
  <span class="syn-kw">except</span> <span class="syn-type">CatchableError</span> <span class="syn-kw">as</span> e:
    <span class="syn-fn">reportError</span>(<span class="syn-str">"Extension Error ["</span> & $e.name & <span class="syn-str">"]: "</span> & e.msg)`,

  enums: `<span class="syn-cmt"># Postgres Enum & Composite Tuple Conversion</span>
<span class="syn-kw">type</span>
  CardType = <span class="syn-kw">enum</span> Debit, Credit
  UserRecord = <span class="syn-kw">tuple</span>[id: <span class="syn-type">int32</span>, name: <span class="syn-type">string</span>]

<span class="syn-kw">proc</span> <span class="syn-fn">process_card</span>*(c: <span class="syn-type">CardType</span>): <span class="syn-type">string</span> =
  <span class="syn-kw">case</span> c
  <span class="syn-kw">of</span> Debit: <span class="syn-str">"Debit Card Transaction"</span>
  <span class="syn-kw">of</span> Credit: <span class="syn-str">"Credit Card Transaction"</span>`,

  hooks: `<span class="syn-cmt"># Low-Level Engine Hook Interceptor</span>
<span class="syn-kw">import</span> pgxcrown/hooks/emit_hook

<span class="syn-cmt"># Intercept internal PostgreSQL emit_log diagnostics</span>
<span class="syn-kw">proc</span> <span class="syn-fn">audit_logger</span>*(edata: <span class="syn-type">ptr ErrorData</span>) <span class="syn-pragma">{.cdecl.}</span> =
  <span class="syn-kw">if</span> edata.elevel >= ERROR:
    <span class="syn-fn">report</span>(NOTICE, <span class="syn-str">"Pgxcrown Audit Hook Intercepted Query Failure!"</span>)`
};

function initCodeTabs() {
  const tabs = document.querySelectorAll('.code-card .tab-btn');
  const codeDisplay = document.getElementById('codeDisplay');
  if (!codeDisplay) return;

  codeDisplay.innerHTML = codeSnippets['nim'];

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      const key = tab.getAttribute('data-tab');
      if (codeSnippets[key]) {
        codeDisplay.innerHTML = codeSnippets[key];
        if (window.anime) {
          anime({
            targets: codeDisplay,
            opacity: [0.4, 1],
            translateY: [4, 0],
            duration: 250,
            easing: 'easeOutCubic'
          });
        }
      }
    });
  });
}

/* --------------------------------------------------------------------------
   2. CLI Terminal Simulator
   -------------------------------------------------------------------------- */
const cliLogs = {
  'pgxtool init': [
    { text: 'Initializing working directory: ~/.pgxtool', type: 'info' },
    { text: 'Created workspace configuration: ~/.pgxtool/config.json', type: 'success' },
    { text: '✓ Working directory ready for scaffolding extensions.', type: 'success' }
  ],
  'pgxtool create-project my_extension': [
    { text: '[pgxtool] Scaffolding extension project: "my_extension"', type: 'info' },
    { text: '  ├─ Created directory: ~/.pgxtool/my_extension/src', type: 'info' },
    { text: '  └─ Initialized entry point: ~/.pgxtool/my_extension/src/main.nim', type: 'info' },
    { text: '✓ Project "my_extension" scaffolded successfully!', type: 'success' }
  ],
  'pgxtool create-hook emit_log': [
    { text: '[pgxtool] Scaffolding PostgreSQL hook interceptor: "emit_log"', type: 'info' },
    { text: '  └─ Initialized hook template: ~/.pgxtool/emit_log/src/main.nim', type: 'info' },
    { text: '✓ Hook template "emit_log" created cleanly!', type: 'success' }
  ],
  'pgxtool build-extension my_extension': [
    { text: '[pgxtool] Compiling native release extension for "my_extension"...', type: 'info' },
    { text: '  • Executing: nim c -d:release --mm:orc --cc:gcc --app:lib -o:"my_extension.so" src/main.nim', type: 'info' },
    { text: '  • Applying v0.12.0 Automatic Panic Shield: ENABLED', type: 'warn' },
    { text: '  • Output binary generated: my_extension.so (512 KB)', type: 'info' },
    { text: 'Build completed for extension: my_extension', type: 'success' }
  ],
  'pgxtool install my_extension': [
    { text: 'Installing extension \'my_extension\' into PostgreSQL...', type: 'info' },
    { text: '  Copying library to /usr/lib/postgresql/14/lib/...', type: 'info' },
    { text: '  Copying control & SQL files to /usr/share/postgresql/14/extension/...', type: 'info' },
    { text: 'Extension \'my_extension\' installed successfully!', type: 'success' }
  ],
  'pgxtool test my_extension': [
    { text: '[pgxtool] Spawning PostgreSQL Docker test harness...', type: 'info' },
    { text: '  • Running: psql -c "CREATE EXTENSION my_extension;"', type: 'info' },
    { text: '  • Testing Panic Shield Overflow Guard: PASSED [ERROR: Extension Defect]', type: 'success' },
    { text: 'All 5 Safety Verification Tests Passed cleanly!', type: 'success' }
  ]
};

function initCliSimulator() {
  const btns = document.querySelectorAll('.cli-btn');
  const termBody = document.getElementById('terminalBody');
  if (!termBody) return;

  function renderCmd(cmdKey) {
    termBody.innerHTML = `<div class="log-line log-info"><strong>$ ${cmdKey}</strong></div>`;
    const logs = cliLogs[cmdKey] || [];
    logs.forEach(log => {
      const line = document.createElement('div');
      line.className = `log-line log-${log.type}`;
      line.textContent = log.text;
      termBody.appendChild(line);
    });

    if (window.anime) {
      anime({
        targets: termBody.querySelectorAll('.log-line'),
        opacity: [0, 1],
        translateY: [4, 0],
        delay: anime.stagger(40),
        duration: 300,
        easing: 'easeOutCubic'
      });
    }
  }

  btns.forEach(btn => {
    btn.addEventListener('click', () => {
      btns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      renderCmd(btn.getAttribute('data-cmd'));
    });
  });

  renderCmd('pgxtool init');
}

/* --------------------------------------------------------------------------
   3. Refined One-Shot Entrance Animations
   -------------------------------------------------------------------------- */
function initAnimeAnimations() {
  if (typeof anime === 'undefined') return;

  // Refined, smooth hero entrance
  anime.timeline({ easing: 'easeOutCubic', duration: 700 })
    .add({ targets: '.navbar', translateY: [-20, 0], opacity: [0, 1] })
    .add({
      targets: '.hero .badge, .hero-title, .hero-desc, .hero-cta, .hero-stats .stat-card',
      translateY: [20, 0],
      opacity: [0, 1],
      delay: anime.stagger(80)
    }, '-=400')
    .add({ targets: '.code-card', translateY: [25, 0], opacity: [0, 1] }, '-=500');

  // Subtle Scroll Observer for Feature Cards
  const observer = new IntersectionObserver((entries) => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const target = entry.target;
        if (target.classList.contains('features-grid')) {
          anime({
            targets: target.querySelectorAll('.feature-card'),
            translateY: [25, 0],
            opacity: [0, 1],
            delay: anime.stagger(80),
            easing: 'easeOutCubic',
            duration: 600
          });
        } else if (target.classList.contains('shield-demo-grid')) {
          anime({
            targets: target.querySelectorAll('.shield-card'),
            translateY: [20, 0],
            opacity: [0, 1],
            delay: anime.stagger(100),
            easing: 'easeOutCubic',
            duration: 650
          });
        }
        observer.unobserve(target);
      }
    });
  }, { threshold: 0.1 });

  const fGrid = document.querySelector('.features-grid');
  const sGrid = document.querySelector('.shield-demo-grid');
  if (fGrid) observer.observe(fGrid);
  if (sGrid) observer.observe(sGrid);
}
