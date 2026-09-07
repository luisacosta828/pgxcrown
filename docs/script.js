/* ==========================================================================
   Pgxcrown v0.23.0 - Architectural Showcase & Interactive Mechanics
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  initHeroCodeTabs();
  initPillarsShowcase();
  initCliSimulator();
  initAnimeAnimations();
});

/* --------------------------------------------------------------------------
   1. Hero Interactive Code Snippets
   -------------------------------------------------------------------------- */
const heroCodeSnippets = {
  pgtext: `<span class="syn-cmt"># Zero-Copy Fast-Path String View (No Allocations, No strlen)</span>
<span class="syn-kw">import</span> pgxcrown, std/strutils

<span class="syn-kw">proc</span> <span class="syn-fn">fast_contains</span>*(haystack: <span class="syn-type">PgText</span>, needle: <span class="syn-type">string</span>): <span class="syn-type">bool</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-cmt"># Direct pointer slice into PostgreSQL varlena buffer (0 memory allocations):</span>
  <span class="syn-kw">return</span> haystack.<span class="syn-fn">contains</span>(needle)

<span class="syn-kw">proc</span> <span class="syn-fn">clean_handle</span>*(input: <span class="syn-type">PgText</span>): <span class="syn-type">string</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-cmt"># Implicit converter enables full std/strutils standard library compatibility:</span>
  <span class="syn-kw">return</span> input.<span class="syn-fn">strip</span>().<span class="syn-fn">toLowerAscii</span>().<span class="syn-fn">replace</span>(<span class="syn-str">"@"</span>, <span class="syn-str">""</span>)`,

  pgvector: `<span class="syn-cmt"># High-Performance Zero-Copy Arrays & Vectors (SIMD-Ready Contiguous Memory)</span>
<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">vector_dot_product</span>*(a, b: <span class="syn-type">PgVector[float64]</span>): <span class="syn-type">float64</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">if</span> a.len != b.len:
    <span class="syn-fn">raisePgError</span>(<span class="syn-str">"ERRCODE_CARDINALITY_VIOLATION"</span>, <span class="syn-str">"Vector dimensions must match"</span>)
  <span class="syn-kw">var</span> sum = 0.0
  <span class="syn-kw">for</span> i <span class="syn-kw">in</span> 0 ..< a.len:
    sum += a[i] * b[i]
  <span class="syn-kw">return</span> sum`,

  sql: `<span class="syn-cmt"># Fluent In-Database SPI Engine & Type-Safe Query Builder AST</span>
<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">get_department_leaders</span>*(minSalary: <span class="syn-type">int32</span> = 80000): <span class="syn-type">string</span> <span class="syn-pragma">{.stable.}</span> =
  <span class="syn-kw">let</span> e = <span class="syn-fn">table</span>(<span class="syn-str">"employees"</span>, <span class="syn-str">"e"</span>)
  <span class="syn-kw">let</span> d = <span class="syn-fn">table</span>(<span class="syn-str">"departments"</span>, <span class="syn-str">"d"</span>)

  <span class="syn-cmt"># Fluent AST: CTE + Window Function + Case When + Inner Join</span>
  <span class="syn-kw">let</span> deptStats = <span class="syn-fn">Select</span>(e.dept_id, <span class="syn-fn">avg</span>(e.salary) <span class="syn-kw">as</span> <span class="syn-str">"avg_sal"</span>).<span class="syn-fn">From</span>(e).<span class="syn-fn">GroupBy</span>(e.dept_id)
  <span class="syn-kw">let</span> q = <span class="syn-fn">WithCte</span>(<span class="syn-str">"stats"</span>, deptStats)
    .<span class="syn-fn">Select</span>(
      e.id, e.name, d.name <span class="syn-kw">as</span> <span class="syn-str">"dept"</span>,
      <span class="syn-fn">rowNumber</span>().<span class="syn-fn">over</span>(partitionBy = e.dept_id, orderBy = e.salary.<span class="syn-fn">desc</span>) <span class="syn-kw">as</span> <span class="syn-str">"rank"</span>
    )
    .<span class="syn-fn">From</span>(e).<span class="syn-fn">InnerJoin</span>(d).<span class="syn-fn">On</span>(e.dept_id == d.id)
    .<span class="syn-fn">Where</span>(e.status == <span class="syn-str">"active"</span> <span class="syn-kw">and</span> e.salary >= minSalary)
    .<span class="syn-fn">OrderBy</span>(e.salary.<span class="syn-fn">desc</span>.<span class="syn-fn">nullsLast</span>)
  <span class="syn-kw">return</span> $q`,

  base_types: `<span class="syn-cmt"># Declarative Custom Base Types (15 Flat Scalar Types)</span>
<span class="syn-kw">import</span> pgxcrown, std/strutils

<span class="syn-cmt"># 1. Custom distinct domain type</span>
<span class="syn-kw">type</span>
  Nickname* <span class="syn-pragma">{.pgxType: string.}</span> = <span class="syn-kw">distinct</span> <span class="syn-type">string</span>

<span class="syn-cmt"># 2. Input parser & Output formatter routines</span>
<span class="syn-kw">proc</span> <span class="syn-fn">parse_nickname</span>*(s: <span class="syn-type">cstring</span>): <span class="syn-type">Nickname</span> <span class="syn-pragma">{.pgxInput, immutable, parallelSafe.}</span> =
  ($s).Nickname

<span class="syn-kw">proc</span> <span class="syn-fn">format_nickname</span>*(val: <span class="syn-type">Nickname</span>): <span class="syn-type">string</span> <span class="syn-pragma">{.pgxOutput, immutable, parallelSafe.}</span> =
  <span class="syn-str">"@"</span> & val.string`,

  shield: `<span class="syn-cmt"># Automatic PG_TRY Safety Shield & SQLSTATE Mapping (0 SIGABRTs)</span>
<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">safe_divide</span>*(a, b: <span class="syn-type">int32</span>): <span class="syn-type">int32</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">if</span> b == 0:
    <span class="syn-cmt"># Custom SQLSTATE exception mapping:</span>
    <span class="syn-fn">raisePgError</span>(ERRCODE_DIVISION_BY_ZERO, <span class="syn-str">"Cannot divide by zero"</span>)
  <span class="syn-kw">return</span> a <span class="syn-kw">div</span> b <span class="syn-cmt"># Defect caught cleanly inside PG_TRY; server never crashes!</span>`,

  testing: `<span class="syn-cmt"># Ephemeral Docker Sandbox Matrix (PG 14, 15, 16, 17)</span>
<span class="syn-cmt"># Run: pgxtool test analytics --all --bless</span>

<span class="syn-sql">CREATE EXTENSION</span> analytics;

<span class="syn-cmt">-- Test zero-copy string function:</span>
<span class="syn-sql">SELECT</span> fast_contains(<span class="syn-str">'pgxcrown high performance'</span>::<span class="syn-type">text</span>, <span class="syn-str">'crown'</span>);

<span class="syn-cmt">-- Test zero-copy SIMD array dot product:</span>
<span class="syn-sql">SELECT</span> vector_dot_product(<span class="syn-sql">ARRAY</span>[1.0, 2.0, 3.0], <span class="syn-sql">ARRAY</span>[4.0, 5.0, 6.0]);`
};

function initHeroCodeTabs() {
  const tabs = document.querySelectorAll('.code-card .tab-btn');
  const codeDisplay = document.getElementById('codeDisplay');
  if (!codeDisplay) return;

  codeDisplay.innerHTML = heroCodeSnippets['pgtext'];

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      const key = tab.getAttribute('data-tab');
      if (heroCodeSnippets[key]) {
        codeDisplay.innerHTML = heroCodeSnippets[key];
        if (window.anime) {
          anime({
            targets: codeDisplay,
            opacity: [0.35, 1],
            translateY: [4, 0],
            duration: 220,
            easing: 'easeOutCubic'
          });
        }
      }
    });
  });
}

/* --------------------------------------------------------------------------
   2. Interactive Capabilities Studio (5 Architectural Pillars)
   -------------------------------------------------------------------------- */
const pillarData = {
  zerocopy: {
    badge: '⚡ Zero-Copy Native Core (v0.23.0)',
    title: 'Zero-Copy Memory-Mapped Architecture',
    desc: 'Direct pointer-slice views over PostgreSQL varlena and array buffers eliminate intermediate memory allocations, strlen overhead, and garbage collection pauses.',
    checklist: [
      '<strong>PgText</strong>: Zero-copy pointer slice directly over PostgreSQL <code>text</code>, <code>varchar</code>, and <code>bpchar</code> data.',
      '<strong>PgVector[T]</strong>: Direct contiguous array memory layout with safe bounds checking and zero heap copying.',
      '<strong>Binary JSONB FFI</strong>: Streamlined engine-level serialization with zero-overhead FFI bindings.',
      '<strong>~500 KB Tiny Binaries</strong>: Ultra-compact native C shared libraries with zero VM overhead.'
    ],
    tags: ['Zero Allocations', 'No strlen', 'SIMD Layout', '~500KB .so', 'Pure Native C'],
    codeHeader: 'src/main.nim (Zero-Copy Engine)',
    code: `<span class="syn-kw">import</span> pgxcrown, std/strutils

<span class="syn-cmt"># Zero-copy text processing directly over PostgreSQL memory:</span>
<span class="syn-kw">proc</span> <span class="syn-fn">search_doc</span>*(doc: <span class="syn-type">PgText</span>, needle: <span class="syn-type">string</span>): <span class="syn-type">bool</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">return</span> doc.<span class="syn-fn">contains</span>(needle)

<span class="syn-cmt"># Zero-copy numeric vector arithmetic:</span>
<span class="syn-kw">proc</span> <span class="syn-fn">dot_product</span>*(a, b: <span class="syn-type">PgVector[float64]</span>): <span class="syn-type">float64</span> <span class="syn-pragma">{.immutable, parallelSafe.}</span> =
  <span class="syn-kw">for</span> i <span class="syn-kw">in</span> 0 ..< a.len:
    <span class="syn-kw">result</span> += a[i] * b[i]`
  },

  shield: {
    badge: '🛡️ Reliability & Security (v0.23.0)',
    title: 'Fail-Safe Panic Shield & SQLSTATE Error Mapping',
    desc: 'Every exported UDF is automatically enclosed in a PG_TRY / PG_CATCH barrier. Defects, panics, and overflows safely abort the transaction with zero SIGABRT server crashes.',
    checklist: [
      '<strong>0 SIGABRT Crashes</strong>: Eliminates backend worker terminations from integer overflows and array defects.',
      '<strong>Typed Exceptions</strong>: First-class <code>PgError</code> and <code>PostgresError</code> with explicit SQLSTATE codes.',
      '<strong>Automated Mapping</strong>: <code>ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE</code>, <code>ERRCODE_DIVISION_BY_ZERO</code>, etc.',
      '<strong>Compile-Time Effects</strong>: <code>{.immutable.}</code> and <code>{.stable.}</code> statically forbid unauthorized DB writes.'
    ],
    tags: ['PG_TRY Barrier', '0 SIGABRTs', 'SQLSTATE Codes', 'Effect Tracking', 'Safe Aborts'],
    codeHeader: 'src/main.nim (Panic Shield & Error Codes)',
    code: `<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">transfer_credits</span>*(sender, receiver: <span class="syn-type">int32</span>, amount: <span class="syn-type">int64</span>): <span class="syn-type">bool</span> <span class="syn-pragma">{.volatile.}</span> =
  <span class="syn-kw">if</span> amount <= 0:
    <span class="syn-fn">raisePgError</span>(ERRCODE_INVALID_PARAMETER_VALUE, <span class="syn-str">"Transfer amount must be positive"</span>)
  <span class="syn-kw">if</span> amount > 1_000_000:
    <span class="syn-fn">raisePgError</span>(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE, <span class="syn-str">"Daily limit exceeded"</span>)
  
  <span class="syn-cmt"># Unhandled overflows or panics are caught cleanly by PG_TRY!</span>
  <span class="syn-kw">return</span> <span class="syn-kw">true</span>`
  },

  spi: {
    badge: '👑 Ergonomics & In-Database SPI',
    title: 'Fluent In-Database SPI & Query Builder',
    desc: 'Ergonomic, left-to-right query and DML execution without network roundtrips. Clean method chaining with full RETURNING support and zero discard boilerplate.',
    checklist: [
      '<strong>Fluent Terminal Chains</strong>: <code>.scalar()</code>, <code>.first()</code>, <code>.all()</code>, <code>.rows()</code>, <code>.run()</code>.',
      '<strong>Zero "discard" Boilerplate</strong>: Clean DML execution via fluent <code>.run()</code>.',
      '<strong>Multi-Column RETURNING</strong>: Read generated keys or modified tuples directly into typed Nim objects.',
      '<strong>Type-Safe AST Query Builder</strong>: CTEs, Window Functions, Case When, Joins, and Polymorphic OrderBy.'
    ],
    tags: ['Fluent SPI', 'No Discard', 'RETURNING', 'CTEs & Windows', 'Type-Safe AST'],
    codeHeader: 'src/main.nim (In-Database SPI Execution)',
    code: `<span class="syn-kw">import</span> pgxcrown

<span class="syn-cmt"># 1. Fluent DML with RETURNING:</span>
<span class="syn-kw">let</span> newId = <span class="syn-fn">InsertInto</span>(<span class="syn-str">"users"</span>, <span class="syn-str">"name"</span>)
  .<span class="syn-fn">Values</span>(<span class="syn-str">"'ada'"</span>)
  .<span class="syn-fn">Returning</span>(<span class="syn-str">"id"</span>)
  .<span class="syn-fn">scalar</span>(<span class="syn-type">int32</span>)

<span class="syn-cmt"># 2. Fluent Query to Nim Object:</span>
<span class="syn-kw">let</span> users = <span class="syn-fn">Select</span>(u.id, u.username)
  .<span class="syn-fn">From</span>(u)
  .<span class="syn-fn">Where</span>(u.score > 80.0)
  .<span class="syn-fn">all</span>(User)`
  },

  types: {
    badge: '📦 Universal Type System',
    title: 'Universal Objects & Declarative Base Types',
    desc: 'Pure Nim object types automatically emit CREATE TYPE AS (...) DDL with bidirectional binary marshaling, accompanied by declarative custom domain base types.',
    checklist: [
      '<strong>Universal Object Types</strong>: Direct binary serialization between Nim objects and PostgreSQL HeapTuples.',
      '<strong>Declarative Domain Types</strong>: <code>{.pgxType.}</code> generates custom distinct types with dynamic input/output.',
      '<strong>15 Flat Scalar Types</strong>: <code>int</code>, <code>float</code>, <code>string</code>, <code>bool</code>, unsigned integers, and char.',
      '<strong>PostgreSQL ENUMs</strong>: Strongly-typed enum mapping and automatic DDL generation.'
    ],
    tags: ['Auto DDL', 'HeapTuple FFI', '15 Scalar Types', 'Distinct Types', 'Enums'],
    codeHeader: 'src/main.nim (Universal Objects & Base Types)',
    code: `<span class="syn-kw">import</span> pgxcrown

<span class="syn-cmt"># Named composite type -> CREATE TYPE "UserProfile" AS (...)</span>
<span class="syn-kw">type</span>
  UserProfile* = <span class="syn-kw">object</span>
    id*: <span class="syn-type">int32</span>
    handle*: <span class="syn-type">string</span>
    score*: <span class="syn-type">float64</span>

<span class="syn-cmt"># Custom domain base type -> distinct scalar with parser:</span>
<span class="syn-kw">type</span>
  Nickname* <span class="syn-pragma">{.pgxType: string.}</span> = <span class="syn-kw">distinct</span> <span class="syn-type">string</span>`
  },

  tooling: {
    badge: '🚀 Developer Experience (v0.23.0)',
    title: 'Smart Toolchain with Sub-15ms Incremental Builds',
    desc: 'pgxtool manages extension scaffolding, incremental compilation caching, automated gitignore management, and multi-version Docker sandbox testing.',
    checklist: [
      '<strong>Sub-15ms Incremental Rebuilds</strong>: Deterministic SHA-256 source hashing with .pgx_build manifest.',
      '<strong>Isolated Nimcache</strong>: Per-project C artifacts prevent global cache invalidation.',
      '<strong>Instant Clean Command</strong>: <code>pgxtool clean &lt;name&gt;</code> removes build cache and artifacts instantly.',
      '<strong>Ephemeral Docker Sandboxes</strong>: Test extensions against PostgreSQL 14–17 with golden diff snapshots (<code>--bless</code>).'
    ],
    tags: ['< 15ms Cache', 'Isolated Nimcache', 'Docker PG 14-17', 'Golden Snapshots', 'pgxtool clean'],
    codeHeader: 'Terminal Commands',
    code: `<span class="syn-cmt"># Instant sub-15ms incremental build:</span>
$ pgxtool build-extension analytics

<span class="syn-cmt"># Clean build cache and generated artifacts:</span>
$ pgxtool clean analytics

<span class="syn-cmt"># Run regression tests in isolated ephemeral Docker container:</span>
$ pgxtool test analytics --all --bless`
  }
};

function initPillarsShowcase() {
  const tabs = document.querySelectorAll('.pillar-tab');
  const badgeEl = document.getElementById('pillarBadge');
  const titleEl = document.getElementById('pillarTitle');
  const descEl = document.getElementById('pillarDesc');
  const listEl = document.getElementById('pillarList');
  const tagsEl = document.getElementById('pillarTags');
  const codeHeaderEl = document.getElementById('pillarCodeHeader');
  const codeEl = document.getElementById('pillarCode');

  if (!tabs.length || !titleEl) return;

  function setPillar(key) {
    const data = pillarData[key];
    if (!data) return;

    if (badgeEl) badgeEl.textContent = data.badge;
    if (titleEl) titleEl.textContent = data.title;
    if (descEl) descEl.textContent = data.desc;
    if (codeHeaderEl) codeHeaderEl.textContent = data.codeHeader;
    if (codeEl) codeEl.innerHTML = data.code;

    if (listEl) {
      listEl.innerHTML = '';
      data.checklist.forEach(item => {
        const li = document.createElement('li');
        li.className = 'pillar-check-item';
        li.innerHTML = `<span class="check-icon">✓</span> <span>${item}</span>`;
        listEl.appendChild(li);
      });
    }

    if (tagsEl) {
      tagsEl.innerHTML = '';
      data.tags.forEach(tag => {
        const span = document.createElement('span');
        span.className = 'pillar-pill';
        span.textContent = tag;
        tagsEl.appendChild(span);
      });
    }

    if (window.anime) {
      anime({
        targets: '#pillarCard',
        opacity: [0.6, 1],
        translateY: [6, 0],
        duration: 250,
        easing: 'easeOutCubic'
      });
    }
  }

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      const key = tab.getAttribute('data-pillar');
      setPillar(key);
    });
  });

  // Default to zerocopy
  setPillar('zerocopy');
}

/* --------------------------------------------------------------------------
   3. CLI Terminal Simulator (Updated for v0.23.0)
   -------------------------------------------------------------------------- */
const cliLogs = {
  'pgxtool init': [
    { text: 'Initializing working directory: ~/.pgxtool', type: 'info' },
    { text: 'Created workspace configuration: ~/.pgxtool/config.json', type: 'success' },
    { text: '✓ Working directory ready for scaffolding extensions.', type: 'success' }
  ],
  'pgxtool create-project analytics': [
    { text: '[pgxtool] Scaffolding extension project: "analytics"', type: 'info' },
    { text: '  ├─ Created directory: ~/.pgxtool/analytics/src', type: 'info' },
    { text: '  ├─ Created directory: ~/.pgxtool/analytics/tests/sql', type: 'info' },
    { text: '  └─ Initialized entry point: ~/.pgxtool/analytics/src/main.nim', type: 'info' },
    { text: '✓ Project "analytics" scaffolded successfully!', type: 'success' }
  ],
  'pgxtool create-type nickname --base-type string': [
    { text: '[pgxtool] Generating custom distinct scalar base type "nickname"...', type: 'info' },
    { text: '  • Selected Base Type: string (mapped to returnPgText / text)', type: 'info' },
    { text: '  • Generated parse_nickname & format_nickname routines', type: 'success' },
    { text: '  • Initialized regression test: tests/sql/01_basic.sql', type: 'success' },
    { text: '✓ Custom type "nickname" generated cleanly!', type: 'success' }
  ],
  'pgxtool build-extension analytics': [
    { text: '⚡ Incremental check: sources and configuration unchanged.', type: 'success' },
    { text: '⚡ Re-using existing shared library: analytics.so (0.012s)', type: 'success' },
    { text: '🛡️  [SECURITY AUDIT PASSED] No blacklisted OS system calls detected', type: 'info' },
    { text: 'Build completed for extension: analytics in 12ms', type: 'success' }
  ],
  'pgxtool clean analytics': [
    { text: '🧹 Removing .pgx_build cache and temporary wrapper files...', type: 'info' },
    { text: '🧹 Removing compiled binaries (.so), SQL DDL, and .control manifest...', type: 'info' },
    { text: '✓ Cleaned build artifacts and cache for extension "analytics".', type: 'success' }
  ],
  'pgxtool test analytics': [
    { text: '🔍 Container Engine: Docker (/usr/bin/docker)', type: 'info' },
    { text: '🐘 Pgxcrown Test Runner [PostgreSQL 16 via Docker]', type: 'info' },
    { text: '🚀 [1/4] Starting PostgreSQL 16 sandbox container...', type: 'info' },
    { text: '📦 [2/4] Injecting extension "analytics" into PostgreSQL engine...', type: 'info' },
    { text: '🗄️  [3/4] Creating clean database "pgxtool_test_analytics" and loading extension...', type: 'info' },
    { text: '🧪 [4/4] Executing SQL regression tests...', type: 'info' },
    { text: '   • tests/sql/01_basic.sql ...... ✅ PASSED (14ms)', type: 'success' },
    { text: '🎉 PG 16 ALL TESTS PASSED (1/1)', type: 'success' }
  ],
  'pgxtool test analytics --all': [
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
  }

  btns.forEach(btn => {
    btn.addEventListener('click', () => {
      btns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const cmdKey = btn.getAttribute('data-cmd');
      renderCmd(cmdKey);
    });
  });

  renderCmd('pgxtool build-extension analytics');
}

/* --------------------------------------------------------------------------
   4. Entrance Animations
   -------------------------------------------------------------------------- */
function initAnimeAnimations() {
  if (!window.anime) return;

  anime({
    targets: '.hero-content > *',
    opacity: [0, 1],
    translateY: [15, 0],
    delay: anime.stagger(80),
    duration: 650,
    easing: 'easeOutCubic'
  });

  anime({
    targets: '.code-card',
    opacity: [0, 1],
    scale: [0.97, 1],
    duration: 750,
    easing: 'easeOutCubic',
    delay: 200
  });
}
