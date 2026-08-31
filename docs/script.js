/* ==========================================================================
   Pgxcrown v0.19.0 - Product Showcase & Interactive Mechanics
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
  sql: `<span class="syn-cmt"># Type-Safe Query Builder AST & In-Database SPI</span>
<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">get_leaders</span>*(minSalary: <span class="syn-type">int</span> = 80000): <span class="syn-type">string</span> <span class="syn-pragma">{.stable.}</span> =
  <span class="syn-kw">let</span> e = <span class="syn-fn">table</span>(<span class="syn-str">"employees"</span>, <span class="syn-str">"e"</span>)
  <span class="syn-kw">let</span> d = <span class="syn-fn">table</span>(<span class="syn-str">"departments"</span>, <span class="syn-str">"d"</span>)

  <span class="syn-cmt"># CTE + Window Function + Case When + Inner Join</span>
  <span class="syn-kw">let</span> q = <span class="syn-fn">WithCte</span>(<span class="syn-str">"stats"</span>, <span class="syn-fn">Select</span>(e.dept_id, <span class="syn-fn">avg</span>(e.salary)).<span class="syn-fn">From</span>(e).<span class="syn-fn">GroupBy</span>(e.dept_id))
    .<span class="syn-fn">Select</span>(
      e.id, e.name, d.name <span class="syn-kw">as</span> <span class="syn-str">"dept_name"</span>,
      <span class="syn-fn">rowNumber</span>().<span class="syn-fn">over</span>(partitionBy = e.dept_id, orderBy = e.salary.<span class="syn-fn">desc</span>) <span class="syn-kw">as</span> <span class="syn-str">"rank"</span>
    )
    .<span class="syn-fn">From</span>(e)
    .<span class="syn-fn">InnerJoin</span>(d).<span class="syn-fn">On</span>(e.dept_id == d.id)
    .<span class="syn-fn">Where</span>(e.status == <span class="syn-str">"active"</span> <span class="syn-kw">and</span> e.salary >= minSalary)
    .<span class="syn-fn">OrderBy</span>(e.salary.<span class="syn-fn">desc</span>.<span class="syn-fn">nullsLast</span>)

  <span class="syn-kw">return</span> $q`,

  base_types: `<span class="syn-cmt"># Declarative Custom Base Types (15 Flat Scalar Types)</span>
<span class="syn-kw">import</span> pgxcrown, std/strutils

<span class="syn-cmt"># 1. Declare custom distinct base type</span>
<span class="syn-kw">type</span>
  Temperature* <span class="syn-pragma">{.pgxType: float64.}</span> = <span class="syn-kw">distinct</span> <span class="syn-type">float64</span>

<span class="syn-cmt"># 2. Input parser & Output formatter routines</span>
<span class="syn-kw">proc</span> <span class="syn-fn">parse_Temperature</span>*(s: <span class="syn-type">cstring</span>): <span class="syn-type">Temperature</span> <span class="syn-pragma">{.pgxInput, immutable, parallelSafe.}</span> =
  <span class="syn-kw">return</span> Temperature(<span class="syn-fn">parseFloat</span>($s))

<span class="syn-kw">proc</span> <span class="syn-fn">format_Temperature</span>*(val: <span class="syn-type">Temperature</span>): <span class="syn-type">string</span> <span class="syn-pragma">{.pgxOutput, immutable, parallelSafe.}</span> =
  <span class="syn-kw">return</span> $(float64(val)) & <span class="syn-str">" °C"</span>

<span class="syn-cmt"># 3. UDF receiving and returning the custom type</span>
<span class="syn-kw">proc</span> <span class="syn-fn">to_fahrenheit</span>*(t: <span class="syn-type">Temperature</span>): <span class="syn-type">Temperature</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">return</span> Temperature(float64(t) * 1.8 + 32.0)`,

  objects: `<span class="syn-cmt"># Universal 'type object' & Named Composite Types (Auto CREATE TYPE)</span>
<span class="syn-kw">import</span> pgxcrown, std/[options, json]

<span class="syn-kw">type</span>
  User* = <span class="syn-kw">object</span>
    id*: <span class="syn-type">int32</span>
    username*: <span class="syn-type">string</span>
    score*: <span class="syn-type">float64</span>
    active*: <span class="syn-type">bool</span>
    profile*: <span class="syn-type">JsonNode</span>

<span class="syn-cmt"># 1. Pure entity constructor -> IMMUTABLE PARALLEL SAFE</span>
<span class="syn-kw">proc</span> <span class="syn-fn">make_user</span>*(id: <span class="syn-type">int32</span>, name: <span class="syn-type">string</span>, score: <span class="syn-type">float64</span>): <span class="syn-type">User</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">return</span> User(id: id, username: name, score: score, active: true, profile: %*{<span class="syn-str">"tier"</span>: <span class="syn-str">"pro"</span>})

<span class="syn-cmt"># 2. Query Builder + SPI object mapping -> RETURNS SETOF "User"</span>
<span class="syn-kw">proc</span> <span class="syn-fn">get_top_users</span>*(minScore: <span class="syn-type">float64</span>): <span class="syn-type">seq[User]</span> <span class="syn-pragma">{.stable.}</span> =
  <span class="syn-kw">let</span> u = <span class="syn-fn">table</span>(<span class="syn-str">"users"</span>, <span class="syn-str">"u"</span>)
  <span class="syn-kw">let</span> q = <span class="syn-fn">Select</span>(u.id, u.username, u.score, u.active, u.profile).<span class="syn-fn">From</span>(u).<span class="syn-fn">Where</span>(u.score >= minScore)
  <span class="syn-kw">return</span> q.<span class="syn-fn">fetch</span>(User)`,

  jsonb: `<span class="syn-cmt"># Native Binary JSONB (Direct PostgreSQL engine representation)</span>
<span class="syn-kw">import</span> pgxcrown, std/json

<span class="syn-kw">proc</span> <span class="syn-fn">enrich_metadata</span>*(data: <span class="syn-type">JsonNode</span>): <span class="syn-type">JsonNode</span> <span class="syn-pragma">{.immutable.}</span> =
  <span class="syn-kw">result</span> = data.copy()
  <span class="syn-kw">result</span>[<span class="syn-str">"verified"</span>] = %true
  <span class="syn-kw">result</span>[<span class="syn-str">"processed_by"</span>] = %<span class="syn-str">"pgxcrown"</span>

<span class="syn-kw">proc</span> <span class="syn-fn">default_config</span>*(): <span class="syn-type">JsonNode</span> <span class="syn-pragma">{.immutable.}</span> =
  <span class="syn-kw">return</span> %*{<span class="syn-str">"env"</span>: <span class="syn-str">"production"</span>, <span class="syn-str">"max_connections"</span>: 100, <span class="syn-str">"metrics"</span>: true}`,

  security: `<span class="syn-cmt"># SQL Volatility Pragmas & Compile-Time Safety</span>
<span class="syn-kw">proc</span> <span class="syn-fn">calc_tax</span>*(price: <span class="syn-type">float64</span>): <span class="syn-type">float64</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">return</span> price * 1.16  <span class="syn-cmt"># IMMUTABLE PARALLEL SAFE</span>

<span class="syn-kw">proc</span> <span class="syn-fn">find_user</span>*(id: <span class="syn-type">int32</span>): <span class="syn-type">Option[User]</span> <span class="syn-pragma">{.stable.}</span> =
  <span class="syn-kw">let</span> u = <span class="syn-fn">table</span>(<span class="syn-str">"users"</span>, <span class="syn-str">"u"</span>)
  <span class="syn-kw">return</span> <span class="syn-fn">Select</span>(u.id, u.username).<span class="syn-fn">From</span>(u).<span class="syn-fn">Where</span>(u.id == id).<span class="syn-fn">fetchOne</span>(User)`,

  testing: `<span class="syn-cmt"># Isolated Docker Sandbox Testing (0 Host Mutation)</span>
<span class="syn-cmt"># $ pgxtool test my_extension --all --bless</span>

<span class="syn-cmt"># 1. SQL Test Case (tests/sql/01_basic.sql)</span>
CREATE EXTENSION my_extension;
SELECT to_fahrenheit('100'::temperature);
SELECT make_user(1, 'Luis', 98.5);

<span class="syn-cmt"># 2. Automated Golden Snapshot Diffing</span>
<span class="syn-cmt"># • Compiles binary -> Injects into ephemeral Postgres container</span>
<span class="syn-cmt"># • Runs test suite across PG 14, 15, 16, 17</span>
<span class="syn-cmt"># • Generates/blesses tests/expected/01_basic.out</span>`,

  shield: `<span class="syn-cmt"># Automatic Panic & Exception Shield (0 SIGABRTs)</span>
<span class="syn-kw">func</span> <span class="syn-fn">pgx_proof_integer_overflow</span>(): <span class="syn-type">Datum</span> <span class="syn-pragma">{.pgv1, trusted.}</span> =
  <span class="syn-kw">try</span>:
    <span class="syn-kw">var</span> a: <span class="syn-type">cint</span> = getInt32(0)
    <span class="syn-kw">var</span> b: <span class="syn-type">cint</span> = getInt32(1)
    <span class="syn-kw">return</span> a + b  <span class="syn-cmt"># OverflowDefect caught cleanly without crashing server!</span>
  <span class="syn-kw">except</span> <span class="syn-type">Defect</span> <span class="syn-kw">as</span> e:
    <span class="syn-fn">reportError</span>(<span class="syn-str">"Extension Defect ["</span> & $e.name & <span class="syn-str">"]: "</span> & e.msg)
  <span class="syn-kw">except</span> <span class="syn-type">CatchableError</span> <span class="syn-kw">as</span> e:
    <span class="syn-fn">reportError</span>(<span class="syn-str">"Extension Error ["</span> & $e.name & <span class="syn-str">"]: "</span> & e.msg)`
};

function initCodeTabs() {
  const tabs = document.querySelectorAll('.code-card .tab-btn');
  const codeDisplay = document.getElementById('codeDisplay');
  if (!codeDisplay) return;

  codeDisplay.innerHTML = codeSnippets['sql'];

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
  'pgxtool create-type temperature --base-type float64': [
    { text: '[pgxtool] Generating custom distinct scalar base type "temperature"...', type: 'info' },
    { text: '  • Selected Base Type: float64 (mapped to parseFloat / float8)', type: 'info' },
    { text: '  • Generated parse_temperature & format_temperature routines', type: 'success' },
    { text: '  • Initialized test suite: tests/sql/01_basic.sql', type: 'success' },
    { text: '✓ Custom type "temperature" generated cleanly!', type: 'success' }
  ],
  'pgxtool create-hook emit_log': [
    { text: '[pgxtool] Scaffolding PostgreSQL hook interceptor: "emit_log"', type: 'info' },
    { text: '  └─ Initialized hook template: ~/.pgxtool/emit_log/src/main.nim', type: 'info' },
    { text: '✓ Hook template "emit_log" created cleanly!', type: 'success' }
  ],
  'pgxtool build-extension my_extension': [
    { text: '[pgxtool] Compiling native release extension for "my_extension"...', type: 'info' },
    { text: '  • Executing: nim c -d:release --mm:orc --cc:gcc --app:lib -o:"my_extension.so" src/main.nim', type: 'info' },
    { text: '  • Applying Automatic Panic Shield: ENABLED (0 SIGABRTs)', type: 'warn' },
    { text: '  • Binary Security Audit: PASSED (No blacklisted OS calls detected)', type: 'success' },
    { text: '  • Output binary generated: my_extension.so (512 KB)', type: 'info' },
    { text: 'Build completed for extension: my_extension', type: 'success' }
  ],
  'pgxtool install my_extension': [
    { text: 'Installing extension \'my_extension\' into PostgreSQL...', type: 'info' },
    { text: '  Copying library to /usr/lib/postgresql/16/lib/...', type: 'info' },
    { text: '  Copying control & SQL files to /usr/share/postgresql/16/extension/...', type: 'info' },
    { text: 'Extension \'my_extension\' installed successfully!', type: 'success' }
  ],
  'pgxtool test my_extension': [
    { text: '🔍 Container Engine: Docker (/usr/bin/docker)', type: 'info' },
    { text: '🐘 Pgxcrown Test Runner [PostgreSQL 16 via Docker]', type: 'info' },
    { text: '🚀 [1/4] Starting PostgreSQL 16 sandbox container...', type: 'info' },
    { text: '📦 [2/4] Injecting extension \'my_extension\' into PostgreSQL engine...', type: 'info' },
    { text: '🗄️  [3/4] Creating clean database \'pgxtool_test_my_extension\' and loading extension...', type: 'info' },
    { text: '🧪 [4/4] Executing SQL regression tests...', type: 'info' },
    { text: '   • tests/sql/01_basic.sql ...... ✅ PASSED (14ms)', type: 'success' },
    { text: '🎉 PG 16 ALL TESTS PASSED (1/1)', type: 'success' }
  ],
  'pgxtool test my_extension --all': [
    { text: '🔍 Container Engine: Docker (/usr/bin/docker)', type: 'info' },
    { text: '🐘 Pgxcrown Multi-Version Test Matrix (PG 14, 15, 16, 17)', type: 'info' },
    { text: '  ├─ [PG 14] tests/sql/01_basic.sql ...... ✅ PASSED (16ms)', type: 'success' },
    { text: '  ├─ [PG 15] tests/sql/01_basic.sql ...... ✅ PASSED (15ms)', type: 'success' },
    { text: '  ├─ [PG 16] tests/sql/01_basic.sql ...... ✅ PASSED (14ms)', type: 'success' },
    { text: '  └─ [PG 17] tests/sql/01_basic.sql ...... ✅ PASSED (14ms)', type: 'success' },
    { text: '🎉 ALL VERSIONS PASSED: 4/4 environments successful!', type: 'success' }
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
