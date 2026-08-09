/* ==========================================================================
   Pgxcrown - Product Showcase & Interactive CLI Logic
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  initCodeTabs();
  initCliSimulator();
  initCopyButtons();
});

/* --------------------------------------------------------------------------
   1. Live Code Snippets (Actual Pgxcrown Capabilities)
   -------------------------------------------------------------------------- */
const codeSnippets = {
  nim: `<span class="syn-cmt"># 1. Write your Nim extension procedure</span>
<span class="syn-kw">import</span> pgxcrown

<span class="syn-kw">proc</span> <span class="syn-fn">add_numbers</span>*(a: <span class="syn-type">int32</span>, b: <span class="syn-type">int32</span>): <span class="syn-type">int32</span> =
  <span class="syn-kw">return</span> a + b

<span class="syn-cmt"># 2. Automatically compiled into native C & bound at build time!</span>
<span class="syn-sql">CREATE OR REPLACE FUNCTION add_numbers(int4, int4) RETURNS int4 as</span>
<span class="syn-sql">'$libdir/my_extension', 'pgx_add_numbers'</span>
<span class="syn-sql">LANGUAGE c STRICT;</span>`,

  sql: `<span class="syn-cmt"># Auto-generated SQL extension script (my_extension.sql)</span>
<span class="syn-sql">CREATE OR REPLACE FUNCTION add_numbers(int4, int4) RETURNS int4 as</span>
<span class="syn-sql">'$libdir/my_extension', 'pgx_add_numbers'</span>
<span class="syn-sql">LANGUAGE c STRICT;</span>

<span class="syn-cmt"># Auto-generated extension manifest (my_extension.control)</span>
<span class="syn-cmt"># my_extension extension</span>
<span class="syn-sql">comment = 'my_extension extension for PostgreSQL'</span>
<span class="syn-sql">default_version = '0.0.1'</span>
<span class="syn-sql">module_pathname = '$libdir/my_extension'</span>
<span class="syn-sql">relocatable = true</span>`,

  hook: `<span class="syn-cmt"># Intercept low-level PostgreSQL engine hooks</span>
<span class="syn-kw">import</span> pgxcrown
<span class="syn-kw">import</span> pgxcrown/hooks/emit_hook

<span class="syn-cmt"># Custom proc intercepting PostgreSQL internal log diagnostics</span>
<span class="syn-kw">proc</span> <span class="syn-fn">custom_proc</span>*(edata: <span class="syn-type">ptr ErrorData</span>) <span class="syn-pragma">{.cdecl.}</span> =
  <span class="syn-fn">report</span>(NOTICE, <span class="syn-str">"Intercepted PostgreSQL diagnostic message in real-time"</span>)`
};

function initCodeTabs() {
  const tabs = document.querySelectorAll('.code-card .tab-btn');
  const codeDisplay = document.getElementById('codeDisplay');
  if (!codeDisplay) return;

  tabs.forEach(tab => {
    tab.addEventListener('click', () => {
      tabs.forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      const key = tab.getAttribute('data-tab');
      if (codeSnippets[key]) {
        codeDisplay.innerHTML = codeSnippets[key];
      }
    });
  });
}

/* --------------------------------------------------------------------------
   2. CLI Terminal Simulator (Mirrors Real `pgxtool` Output)
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
    { text: '  ├─ Created directory: ~/.pgxtool/my_extension/private', type: 'info' },
    { text: '  └─ Initialized entry point: ~/.pgxtool/my_extension/src/main.nim', type: 'info' },
    { text: '✓ Project "my_extension" scaffolded successfully!', type: 'success' }
  ],
  'pgxtool create-hook emit_log': [
    { text: '[pgxtool] Scaffolding PostgreSQL hook interceptor: "emit_log"', type: 'info' },
    { text: '  ├─ Created directory: ~/.pgxtool/emit_log/src', type: 'info' },
    { text: '  └─ Initialized hook template: ~/.pgxtool/emit_log/src/main.nim', type: 'info' },
    { text: '✓ Hook template "emit_log" created cleanly!', type: 'success' }
  ],
  'pgxtool build-extension my_extension': [
    { text: '[pgxtool] Compiling native release extension for "my_extension"...', type: 'info' },
    { text: '  • Executing: nim c -d:release --cc:gcc --app:lib -o:"my_extension" src/main.nim', type: 'info' },
    { text: '  • Validating compile-time IO safety guard: PASSED', type: 'warn' },
    { text: '  • Output binary generated: my_extension.so (684 KB)', type: 'info' },
    { text: 'Build completed for extension: my_extension', type: 'success' },
    { text: 'Install script generated at: ~/.pgxtool/my_extension/src/install.sh', type: 'info' },
    { text: 'To install into PostgreSQL, run:', type: 'warn' },
    { text: '  sudo ~/.pgxtool/my_extension/src/install.sh', type: 'warn' }
  ],
  'pgxtool install my_extension': [
    { text: 'Generated install script: ~/.pgxtool/my_extension/src/install.sh', type: 'info' },
    { text: 'Installing extension \'my_extension\' into PostgreSQL...', type: 'info' },
    { text: '  Copying library to /usr/lib/postgresql/16/lib/...', type: 'info' },
    { text: '  Copying control and SQL files to /usr/share/postgresql/16/extension/...', type: 'info' },
    { text: 'Extension \'my_extension\' installed successfully!', type: 'success' },
    { text: 'To enable it in PostgreSQL, run:', type: 'warn' },
    { text: '  psql -c "CREATE EXTENSION my_extension;"', type: 'warn' }
  ],
  'pgxtool test my_extension': [
    { text: '[pgxtool] Spinning up isolated test container (PostgreSQL 16)...', type: 'info' },
    { text: 'Copying sql file to container pgxtool_test_v16...', type: 'info' },
    { text: 'Copying library file to container /usr/lib/postgresql/16/lib/...', type: 'info' },
    { text: 'Executing: psql -U postgres -f /var/lib/postgresql/my_extension.sql', type: 'info' },
    { text: 'CREATE EXTENSION', type: 'success' },
    { text: 'Executing: psql -U postgres -c "SELECT add_numbers(10, 32);"', type: 'info' },
    { text: ' add_numbers \n-------------\n          42\n(1 row)', type: 'success' },
    { text: '✓ Extension test completed successfully with clean exit code 0.', type: 'success' }
  ]
};

function initCliSimulator() {
  const body = document.getElementById('terminalBody');
  const btns = document.querySelectorAll('.cli-btn');
  if (!body) return;

  function runCmd(cmd) {
    body.innerHTML = '';
    
    const pLine = document.createElement('div');
    pLine.className = 'term-line';
    pLine.innerHTML = `<span class="term-prompt">user@pgxcrown:~$</span> <span class="term-cmd">${cmd}</span>`;
    body.appendChild(pLine);

    const items = cliLogs[cmd] || [];
    items.forEach((item, idx) => {
      setTimeout(() => {
        const line = document.createElement('div');
        line.className = 'term-line';
        if (item.type === 'info') line.classList.add('term-info');
        if (item.type === 'success') line.classList.add('term-success');
        if (item.type === 'warn') line.classList.add('term-warn');
        line.innerText = item.text;
        body.appendChild(line);
        body.scrollTop = body.scrollHeight;
      }, (idx + 1) * 280);
    });

    setTimeout(() => {
      const ePrompt = document.createElement('div');
      ePrompt.className = 'term-line';
      ePrompt.innerHTML = `<span class="term-prompt">user@pgxcrown:~$</span> <span class="term-cursor"></span>`;
      body.appendChild(ePrompt);
      body.scrollTop = body.scrollHeight;
    }, (items.length + 1) * 280);
  }

  btns.forEach(btn => {
    btn.addEventListener('click', () => {
      btns.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const cmd = btn.getAttribute('data-cmd');
      runCmd(cmd);
    });
  });

  // Default run on page load
  runCmd('pgxtool build-extension my_extension');
}

/* --------------------------------------------------------------------------
   3. Clipboard Copy Buttons
   -------------------------------------------------------------------------- */
function initCopyButtons() {
  const btns = document.querySelectorAll('.copy-btn');
  btns.forEach(btn => {
    btn.addEventListener('click', () => {
      const text = btn.getAttribute('data-copy');
      if (text) {
        navigator.clipboard.writeText(text);
        const orig = btn.innerText;
        btn.innerText = '✓ Copied!';
        btn.style.color = 'var(--emerald-green)';
        setTimeout(() => {
          btn.innerText = orig;
          btn.style.color = '';
        }, 2000);
      }
    });
  });
}
