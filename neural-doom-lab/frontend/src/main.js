import './styles.css';

const STORAGE_KEY = 'doomwasm.selection';
const DEFAULT_IWAD_PATH = '/iwads/freedoom2.wad';
const DEFAULT_IWAD_NAME = 'freedoom2.wad';
const ENGINE_MODULE_URL = `${import.meta.env.BASE_URL}engine/chocolate-doom.js`;
const ENGINE_FILE_BASE = `${import.meta.env.BASE_URL}engine/`;
const AI_WEBSOCKET_URL = 'ws://127.0.0.1:8000/ws/ai';
const AI_MODE = Object.freeze({ ORIGINAL_AI: 0, EXTERNAL_AI: 1 });
const AI_ACTION = Object.freeze({
  INVALID: -1,
  IDLE: 0,
  CHASE: 1,
  ATTACK: 2,
  FLEE: 3,
});
const AI_ACTION_NAME = Object.freeze({
  [AI_ACTION.IDLE]: 'IDLE',
  [AI_ACTION.CHASE]: 'CHASE',
  [AI_ACTION.ATTACK]: 'ATTACK',
  [AI_ACTION.FLEE]: 'FLEE',
});
const KNOWN_IWADS = new Set([
  'chex.wad',
  'doom.wad',
  'doom1.wad',
  'doom2.wad',
  'freedm.wad',
  'freedoom1.wad',
  'freedoom2.wad',
  'plutonia.wad',
  'tnt.wad',
]);
const DEFAULT_MAIN_CONFIG = [
  'fullscreen 0',
  'window_width 320',
  'window_height 200',
  'grabmouse 0',
  'use_mouse 1',
].join('\n');
const DEFAULT_EXTRA_CONFIG = [
  // The web build renders reliably when we skip the intermediate
  // render-target upscale path used on desktop SDL backends.
  'smooth_pixel_scaling 0',
  'force_software_renderer 1',
].join('\n');

const app = document.querySelector('#app');

app.innerHTML = `
  <main class="shell">
    <header class="site-header">
      <a class="brand" href="#top" aria-label="Neural Doom Lab — início">
        <span class="brand-mark" aria-hidden="true">☠</span>
        <span class="brand-copy">
          <strong><em>Neural</em> <span>Doom Lab</span></strong>
          <small>IA jogando Freedoom 2</small>
        </span>
      </a>
      <p class="header-tagline">Experimentos em IA<br />para ambientes complexos<br />de games clássicos.</p>
      <div class="header-actions">
        <span class="status-pill" id="status-pill" data-tone="ready"><i aria-hidden="true"></i>Engine ready</span>
        <nav class="site-nav" aria-label="Navegação principal">
          <a href="#about">Sobre</a><span aria-hidden="true">|</span><a href="https://github.com/GabrielAlex01/Rede-Neural" rel="noreferrer">GitHub</a>
        </nav>
      </div>
      <span class="header-insignia" aria-hidden="true"><strong>UAC</strong><small>Learning<br />different<br />worlds</small></span>
    </header>

    <section class="workbench" id="top">
      <section class="panel session-panel">
        <h2><span class="panel-icon" aria-hidden="true">▰</span>Sessão</h2>
        <dl class="session-data">
          <div><dt>Projeto</dt><dd>Neural Doom Lab</dd></div>
          <div><dt>Status</dt><dd class="live-value"><i aria-hidden="true"></i><span id="session-engine-state">Aguardando Play</span></dd></div>
          <div><dt>WAD</dt><dd id="session-wad">freedoom2.wad</dd></div>
          <div><dt>Modo da IA</dt><dd id="session-ai-mode">ORIGINAL_AI</dd></div>
        </dl>
        <blockquote>“Mesmos demônios.<br />Novas ideias.”</blockquote>
        <div class="session-watermark" aria-hidden="true"><strong>UAC</strong><span>Science<br />through<br />play</span></div>
      </section>

      <div class="viewport-frame">
        <div class="viewport-heading">
          <strong><span class="panel-icon" aria-hidden="true">◆</span>Jogo</strong>
          <div class="viewport-toolbar">
            <div class="actions">
              <button id="play-button" class="button button-primary"><span aria-hidden="true">▶</span> Play</button>
              <button id="fullscreen-button" class="button" disabled><span aria-hidden="true">⛶</span> Fullscreen</button>
              <button id="pointer-button" class="button" disabled><span aria-hidden="true">⌖</span> Pointer</button>
            </div>
          </div>
          <span id="selection-summary">Usando Freedoom 2 (bundle)</span>
        </div>
        <div class="canvas-shell" id="canvas-shell">
          <canvas id="doom-canvas" width="320" height="200" tabindex="0" aria-label="Doom game canvas"></canvas>
          <div class="canvas-overlay" id="canvas-overlay">
            <p>Freedoom 2 pronto para iniciar.</p>
            <small>Carregue um WAD opcional ou pressione Play.</small>
          </div>
        </div>
      </div>

      <section class="panel ai-panel" id="ai-controls">
        <h2><span class="panel-icon" aria-hidden="true">◉</span>Controle da IA</h2>
        <label class="field">
          <span>Modo de operação</span>
          <select id="ai-mode">
            <option value="original">ORIGINAL_AI</option>
            <option value="external">EXTERNAL_AI</option>
          </select>
        </label>
        <label class="field">
          <span>Fonte de decisão</span>
          <select id="ai-provider">
            <option value="backend">MySQL neural (via backend)</option>
            <option value="local">Local mock (desenvolvimento)</option>
          </select>
        </label>
      </section>

      <section class="panel connection-panel">
        <h2><span class="panel-icon" aria-hidden="true">⌁</span>Conexão</h2>
        <div class="connection-status" data-status="disconnected">
          <span class="signal-dot" aria-hidden="true"></span>
          <div><small>WebSocket bridge</small><strong id="ai-debug-backend">Disconnected</strong></div>
        </div>
        <code>ws://127.0.0.1:8000/ws/ai</code>
      </section>

      <section class="panel npc-panel" id="npc-status">
        <h2><span class="panel-icon" aria-hidden="true">☠</span>NPC atual</h2>
        <dl class="ai-debug" id="ai-debug">
          <div><dt>Mode</dt><dd id="ai-debug-mode">ORIGINAL_AI</dd></div>
          <div><dt>NPC</dt><dd id="ai-debug-npc">—</dd></div>
          <div><dt>State</dt><dd id="ai-debug-state">—</dd></div>
          <div><dt>Action</dt><dd id="ai-debug-action">Original engine</dd></div>
        </dl>
      </section>

      <section class="utility-panel controls-panel" id="utilities">
        <h2><span class="panel-icon" aria-hidden="true">⌨</span>Controles</h2>
        <div class="controls">
          <p><span>Mover</span><strong>WASD / setas</strong></p>
          <p><span>Atirar</span><strong>Ctrl</strong></p>
          <p><span>Usar / abrir</span><strong>Espaço</strong></p>
          <p><span>Correr</span><strong>Shift</strong></p>
          <p><span>Pointer look</span><strong>Opcional</strong></p>
        </div>
      </section>

      <section class="utility-panel wad-panel">
        <h2><span class="panel-icon" aria-hidden="true">▤</span>WAD / Arquivos</h2>
        <div class="utility-content">
          <label class="field file-field">
            <span>IWAD / WAD opcional</span>
            <input id="wad-input" type="file" accept=".wad,.iwad" multiple />
          </label>
          <label class="field">
            <span>Interpretar upload como</span>
            <select id="wad-mode">
              <option value="auto">Detectar automaticamente</option>
              <option value="iwad">IWAD personalizado</option>
              <option value="addon">WAD adicional</option>
            </select>
          </label>
          <p class="note">Use somente arquivos que você possui.</p>
          <p class="note note-muted" id="persisted-note"></p>
        </div>
      </section>
    </section>

    <section class="log-panel panel">
      <div class="log-heading">
        <h2><span class="panel-icon" aria-hidden="true">▤</span>Log de eventos</h2>
        <button id="clear-log-button" class="text-button" type="button"><span aria-hidden="true">▰</span> Limpar log</button>
      </div>
      <pre id="log-output" class="log-output" aria-live="polite"></pre>
    </section>

    <footer class="site-footer" id="about">
      <p><strong>Neural Doom Lab</strong> — projeto acadêmico com Freedoom 2.</p>
    </footer>
  </main>
`;

const state = {
  cachedUploads: [],
  engine: null,
  running: false,
  sessionId: null,
  telemetryQueue: [],
};

const playButton = document.querySelector('#play-button');
const fullscreenButton = document.querySelector('#fullscreen-button');
const pointerButton = document.querySelector('#pointer-button');
const wadInput = document.querySelector('#wad-input');
const wadMode = document.querySelector('#wad-mode');
const canvas = document.querySelector('#doom-canvas');
const canvasShell = document.querySelector('#canvas-shell');
const canvasOverlay = document.querySelector('#canvas-overlay');
const statusPill = document.querySelector('#status-pill');
const selectionSummary = document.querySelector('#selection-summary');
const sessionEngineState = document.querySelector('#session-engine-state');
const sessionWad = document.querySelector('#session-wad');
const sessionAiMode = document.querySelector('#session-ai-mode');
const logOutput = document.querySelector('#log-output');
const persistedNote = document.querySelector('#persisted-note');
const aiMode = document.querySelector('#ai-mode');
const aiProvider = document.querySelector('#ai-provider');
const aiDebugMode = document.querySelector('#ai-debug-mode');
const aiDebugNpc = document.querySelector('#ai-debug-npc');
const aiDebugState = document.querySelector('#ai-debug-state');
const aiDebugAction = document.querySelector('#ai-debug-action');
const aiDebugBackend = document.querySelector('#ai-debug-backend');
const connectionStatus = document.querySelector('.connection-status');
const clearLogButton = document.querySelector('#clear-log-button');

function appendLog(level, message) {
  const normalized = String(message ?? '').trim();

  if (!normalized) {
    return;
  }

  if (level === 'error') {
    console.error(normalized);
  } else {
    console.log(normalized);
  }

  const lines = normalized.split('\n');
  const existing = logOutput.textContent ? logOutput.textContent.split('\n') : [];
  const next = [...existing, ...lines].slice(-120);
  logOutput.textContent = next.join('\n');
  logOutput.scrollTop = logOutput.scrollHeight;
}

function mockDecisionProvider(npcState) {
  if (npcState.health <= 20) {
    return AI_ACTION.FLEE;
  }

  if (!npcState.player_visible) {
    return AI_ACTION.CHASE;
  }

  if (npcState.player_distance <= 128) {
    return AI_ACTION.ATTACK;
  }

  return AI_ACTION.CHASE;
}

const aiBridgeState = {
  decisions: new Map(),
  inflight: new Map(),
  lastFallbackLogAt: 0,
  lastRequestAt: 0,
  lastResultLogAt: 0,
  pending: new Map(),
  reconnectTimer: null,
  requestSequence: 0,
  socket: null,
};

function flushTelemetryQueue() {
  if (aiBridgeState.socket?.readyState !== WebSocket.OPEN) {
    return;
  }

  while (state.telemetryQueue.length) {
    const message = state.telemetryQueue.shift();
    if (message.session_id === state.sessionId) {
      aiBridgeState.socket.send(JSON.stringify(message));
    }
  }
}

function sendCombatTelemetry(event) {
  if (!state.sessionId) {
    return;
  }

  const message = {
    type: 'combat_event',
    session_id: state.sessionId,
    event,
  };

  if (aiBridgeState.socket?.readyState === WebSocket.OPEN) {
    aiBridgeState.socket.send(JSON.stringify(message));
    return;
  }

  if (state.telemetryQueue.length >= 500) {
    state.telemetryQueue.shift();
    appendLog('error', '[AI BRIDGE] fila de telemetria cheia; um evento antigo foi descartado.');
  }
  state.telemetryQueue.push(message);
}

function setBackendStatus(status) {
  connectionStatus.dataset.status = status.startsWith('Connected')
    ? 'connected'
    : status.startsWith('Connecting')
      ? 'connecting'
      : status.startsWith('Local')
        ? 'local'
        : status.startsWith('Inativo')
          ? 'inactive'
        : 'disconnected';

  if (aiDebugBackend.textContent !== status) {
    aiDebugBackend.textContent = status;
    appendLog('info', `[AI BRIDGE] backend ${status.toLowerCase()}.`);
  }
}

function scheduleBackendReconnect() {
  if (aiBridgeState.reconnectTimer || aiMode.value !== 'external' || aiProvider.value !== 'backend') {
    return;
  }

  aiBridgeState.reconnectTimer = window.setTimeout(() => {
    aiBridgeState.reconnectTimer = null;
    connectAiBackend();
  }, 2000);
}

function connectAiBackend() {
  if (aiMode.value !== 'external' || aiProvider.value !== 'backend') {
    return;
  }

  if (
    aiBridgeState.socket?.readyState === WebSocket.OPEN
    || aiBridgeState.socket?.readyState === WebSocket.CONNECTING
  ) {
    return;
  }

  setBackendStatus('Connecting');
  const socket = new WebSocket(AI_WEBSOCKET_URL);
  aiBridgeState.socket = socket;

  socket.addEventListener('open', () => {
    setBackendStatus('Connected');
    flushTelemetryQueue();
  });

  socket.addEventListener('message', (event) => {
    try {
      const response = JSON.parse(event.data);

      if (response.type === 'combat_event_ack') {
        if (!response.stored) {
          appendLog('error', `[AI BRIDGE] evento de combate não persistido (${response.reason ?? 'erro'}).`);
        }
        return;
      }

      if (response.type === 'session_end_ack') {
        return;
      }

      const pendingRequest = aiBridgeState.inflight.get(response.request_id);
      aiBridgeState.inflight.delete(response.request_id);

      const action = AI_ACTION[response.action];
      const validResponse = response.type === 'npc_action'
        && pendingRequest
        && response.npc_id === pendingRequest.npcState.npc_id
        && Number.isInteger(action)
        && action !== AI_ACTION.INVALID;

      if (!validResponse) {
        aiBridgeState.decisions.delete(response.npc_id);
        appendLog('error', '[AI BRIDGE] invalid backend response; ORIGINAL_AI fallback active.');
        return;
      }

      aiBridgeState.decisions.set(response.npc_id, {
        action,
        npcState: pendingRequest.npcState,
        receivedAt: Date.now(),
      });
    } catch (error) {
      appendLog('error', `[AI BRIDGE] invalid backend JSON; ORIGINAL_AI fallback active: ${error}`);
    }
  });

  socket.addEventListener('close', () => {
    if (aiBridgeState.socket !== socket) {
      return;
    }

    aiBridgeState.socket = null;
    aiBridgeState.decisions.clear();
    aiBridgeState.inflight.clear();
    setBackendStatus('Disconnected — fallback active');
    scheduleBackendReconnect();
  });

  socket.addEventListener('error', () => {
    if (aiBridgeState.socket === socket) {
      setBackendStatus('Offline — fallback active');
    }
  });
}

function disconnectAiBackend(status = 'Disconnected') {
  if (aiBridgeState.reconnectTimer) {
    window.clearTimeout(aiBridgeState.reconnectTimer);
    aiBridgeState.reconnectTimer = null;
  }

  aiBridgeState.socket?.close();
  aiBridgeState.socket = null;
  aiBridgeState.decisions.clear();
  aiBridgeState.inflight.clear();
  setBackendStatus(status);
}

async function finishAiSession() {
  const sessionId = state.sessionId;
  const socket = aiBridgeState.socket;
  let closed = false;

  if (sessionId) {
    if (socket?.readyState === WebSocket.OPEN) {
      closed = await new Promise((resolve) => {
        const timeout = window.setTimeout(() => finish(false), 2500);
        const onMessage = (event) => {
          try {
            const response = JSON.parse(event.data);
            if (response.type === 'session_end_ack' && response.session_id === sessionId) {
              finish(response.closed === true);
            }
          } catch {
            // The ordinary WebSocket handler logs malformed payloads.
          }
        };

        function finish(result) {
          window.clearTimeout(timeout);
          socket.removeEventListener('message', onMessage);
          resolve(result);
        }

        socket.addEventListener('message', onMessage);
        flushTelemetryQueue();
        socket.send(JSON.stringify({ type: 'session_end', session_id: sessionId }));
      });
    }

    if (!closed) {
      appendLog('error', '[AI BRIDGE] sessão não confirmou encerramento no MySQL; confira a conexão antes de treinar.');
    }
  }

  if (state.sessionId === sessionId) {
    state.sessionId = null;
  }
  state.telemetryQueue = [];
  aiBridgeState.decisions.clear();
  aiBridgeState.inflight.clear();
  return closed;
}

function requestBackendDecision(npcState) {
  const now = Date.now();

  if (now - aiBridgeState.lastRequestAt < 250 || aiBridgeState.socket?.readyState !== WebSocket.OPEN) {
    return;
  }

  const requestId = `${npcState.npc_id}-${now}-${++aiBridgeState.requestSequence}`;
  aiBridgeState.lastRequestAt = now;
  aiBridgeState.inflight.set(requestId, { npcState, sentAt: now });
  aiBridgeState.socket.send(JSON.stringify({
    type: 'npc_state',
    request_id: requestId,
    session_id: state.sessionId,
    npc: npcState,
  }));
}

function renderAiState(npcState, actionLabel) {
  aiDebugNpc.textContent = npcState ? `${npcState.npc_id} (type ${npcState.npc_type})` : '—';
  aiDebugState.textContent = npcState
    ? `state ${npcState.current_state}, hp ${npcState.health}, distance ${npcState.player_distance}`
    : '—';
  aiDebugAction.textContent = actionLabel;
}

globalThis.doomNeuralAIBridge = {
  decide(npcState) {
    if (aiProvider.value === 'backend') {
      connectAiBackend();
      requestBackendDecision(npcState);

      const decision = aiBridgeState.decisions.get(npcState.npc_id);
      if (decision && Date.now() - decision.receivedAt <= 1000) {
        aiBridgeState.pending.set(npcState.npc_id, { action: decision.action, npcState });
        return decision.action;
      }

      const now = Date.now();

      if (now - aiBridgeState.lastFallbackLogAt >= 1000) {
        const reason = aiBridgeState.socket?.readyState === WebSocket.OPEN
          ? 'waiting for backend decision'
          : 'backend offline';
        appendLog('info', `[AI BRIDGE] NPC ${npcState.npc_id}: ${reason}; falling back to ORIGINAL_AI.`);
        renderAiState(npcState, 'Backend pending/offline → ORIGINAL_AI');
        aiBridgeState.lastFallbackLogAt = now;
      }

      return AI_ACTION.INVALID;
    }

    const action = mockDecisionProvider(npcState);
    aiBridgeState.pending.set(npcState.npc_id, { action, npcState });
    return action;
  },

  receiveResult(result) {
    const pending = aiBridgeState.pending.get(result.npc_id);

    if (!pending) {
      return;
    }

    const now = Date.now();

    if (now - aiBridgeState.lastResultLogAt >= 1000) {
      const actionName = AI_ACTION_NAME[result.action] ?? 'INVALID';
      const outcome = result.applied ? 'applied by engine' : 'rejected; ORIGINAL_AI fallback';
      const source = aiProvider.value === 'backend' ? 'MySQL' : 'local mock';
      appendLog('info', `[AI BRIDGE] NPC ${result.npc_id}: state received → ${source} ${actionName} → ${outcome}.`);
      renderAiState(pending.npcState, `${actionName} (${outcome})`);
      aiBridgeState.lastResultLogAt = now;
    }

    aiBridgeState.pending.delete(result.npc_id);
  },

  reportError(error) {
    appendLog('error', `[AI BRIDGE] ${error instanceof Error ? error.message : String(error)}`);
  },

  reportCombatEvent(event) {
    try {
      sendCombatTelemetry({
        event_id: globalThis.crypto.randomUUID(),
        npc_id: event.npc_id,
        event_type: event.event_type,
        value: event.value,
      });
    } catch (error) {
      appendLog('error', `[AI BRIDGE] falha ao identificar evento de combate: ${error}`);
    }
  },
};

function syncAiMode({ log = true } = {}) {
  const isExternal = aiMode.value === 'external';
  const modeValue = isExternal ? AI_MODE.EXTERNAL_AI : AI_MODE.ORIGINAL_AI;
  const modeName = isExternal ? 'EXTERNAL_AI' : 'ORIGINAL_AI';

  aiDebugMode.textContent = modeName;
  sessionAiMode.textContent = modeName;
  aiProvider.disabled = !isExternal;

  if (!isExternal) {
    aiMode.disabled = true;
    state.engine?._DB_SetAIMode?.(modeValue);
    renderAiState(null, 'Original engine');
    void finishAiSession().finally(() => {
      if (aiMode.value === 'original') {
        disconnectAiBackend('Inativo — selecione EXTERNAL_AI');
      }
      aiMode.disabled = false;
    });
  } else if (aiProvider.value === 'backend') {
    aiMode.disabled = false;
    state.sessionId ||= globalThis.crypto.randomUUID();
    connectAiBackend();
  } else {
    aiMode.disabled = false;
    disconnectAiBackend();
    setBackendStatus('Local mock selected');
  }

  if (isExternal && state.engine?._DB_SetAIMode) {
    state.engine._DB_SetAIMode(modeValue);
  }

  if (log) {
    appendLog('info', `[AI BRIDGE] mode set to ${modeName}.`);
  }
}

function setStatus(label, tone = 'ready') {
  const labels = {
    Ready: 'Engine ready',
    'Reading files': 'Lendo arquivos',
    Booting: 'Engine booting',
    Running: 'Engine online',
    Error: 'Engine error',
  };
  const resolvedLabel = labels[label] ?? label;
  statusPill.innerHTML = `<i aria-hidden="true"></i>${resolvedLabel}`;
  statusPill.dataset.tone = tone;
  sessionEngineState.textContent = resolvedLabel;
  sessionEngineState.parentElement.dataset.tone = tone;
}

function sanitizeFilename(name) {
  return name.replace(/[^a-zA-Z0-9._-]/g, '_');
}

function persistSelectionMetadata(files, mode) {
  const payload = {
    files: files.map((file) => file.name),
    mode,
    updatedAt: new Date().toISOString(),
  };

  localStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
}

function restoreSelectionMetadata() {
  const raw = localStorage.getItem(STORAGE_KEY);

  if (!raw) {
    return null;
  }

  try {
    return JSON.parse(raw);
  } catch (error) {
    console.warn('Unable to parse persisted selection metadata.', error);
    return null;
  }
}

function renderPersistedSelection() {
  const persisted = restoreSelectionMetadata();

  if (!persisted?.files?.length) {
    persistedNote.textContent = '';
    return;
  }

  persistedNote.textContent = `Last custom selection: ${persisted.files.join(', ')} (${persisted.mode}). Re-upload required after refresh.`;
}

function summarizeSelection(selection) {
  if (selection.iwad?.runtimePath !== DEFAULT_IWAD_PATH) {
    const addonSuffix = selection.addons.length ? ` + ${selection.addons.length} WAD(s) adicional(is)` : '';
    return `IWAD personalizado: ${selection.iwad.name}${addonSuffix}`;
  }

  if (selection.addons.length) {
    return `Freedoom 2 (bundle) + ${selection.addons.length} WAD(s) adicional(is)`;
  }

  return 'Usando Freedoom 2 (bundle)';
}

function classifyUploads(uploads, mode) {
  if (!uploads.length) {
    return {
      addons: [],
      iwad: { name: DEFAULT_IWAD_NAME, runtimePath: DEFAULT_IWAD_PATH },
    };
  }

  if (mode === 'iwad') {
    const [iwad, ...addons] = uploads;

    return {
      addons: addons.map((file) => ({ ...file, runtimePath: `/mods/${sanitizeFilename(file.name)}` })),
      iwad: { ...iwad, runtimePath: `/uploads/${sanitizeFilename(iwad.name)}` },
    };
  }

  if (mode === 'addon') {
    return {
      addons: uploads.map((file) => ({ ...file, runtimePath: `/mods/${sanitizeFilename(file.name)}` })),
      iwad: { name: DEFAULT_IWAD_NAME, runtimePath: DEFAULT_IWAD_PATH },
    };
  }

  const detectedIwad = uploads.find((file) => KNOWN_IWADS.has(file.name.toLowerCase()));
  const addons = uploads.filter((file) => file !== detectedIwad);

  return {
    addons: addons.map((file) => ({ ...file, runtimePath: `/mods/${sanitizeFilename(file.name)}` })),
    iwad: detectedIwad
      ? { ...detectedIwad, runtimePath: `/uploads/${sanitizeFilename(detectedIwad.name)}` }
      : { name: DEFAULT_IWAD_NAME, runtimePath: DEFAULT_IWAD_PATH },
  };
}

function ensureDir(fs, path) {
  const segments = path.split('/').filter(Boolean);
  let cursor = '';

  for (const segment of segments) {
    cursor += `/${segment}`;

    try {
      fs.mkdir(cursor);
    } catch (error) {
      if (!String(error?.message ?? '').includes('File exists')) {
        throw error;
      }
    }
  }
}

function buildCliArgs(selection) {
  const args = [
    '-window',
    '-iwad',
    selection.iwad.runtimePath,
    '-savedir',
    '/savegames',
    '-config',
    '/config/default.cfg',
    '-extraconfig',
    '/config/chocolate-doom.cfg',
  ];

  if (selection.addons.length) {
    args.push('-file', ...selection.addons.map((addon) => addon.runtimePath));
  }

  return args;
}

function prepareVirtualFilesystem(module, selection) {
  ensureDir(module.FS, '/config');
  ensureDir(module.FS, '/mods');
  ensureDir(module.FS, '/savegames');
  ensureDir(module.FS, '/uploads');

  module.FS.writeFile('/config/default.cfg', `${DEFAULT_MAIN_CONFIG}\n`);
  module.FS.writeFile('/config/chocolate-doom.cfg', `${DEFAULT_EXTRA_CONFIG}\n`);

  if (selection.iwad.bytes) {
    module.FS.writeFile(selection.iwad.runtimePath, selection.iwad.bytes);
  }

  for (const addon of selection.addons) {
    module.FS.writeFile(addon.runtimePath, addon.bytes);
  }
}

function syncSelectionSummary() {
  const selection = classifyUploads(state.cachedUploads, wadMode.value);
  selectionSummary.textContent = summarizeSelection(selection);
  sessionWad.textContent = selection.addons.length
    ? `${selection.iwad.name} + ${selection.addons.length}`
    : selection.iwad.name;
}

async function cacheUploads(files) {
  if (!files.length) {
    state.cachedUploads = [];
    syncSelectionSummary();
    renderPersistedSelection();
    return;
  }

  setStatus('Reading files', 'busy');

  state.cachedUploads = await Promise.all(
    files.map(async (file) => ({
      bytes: new Uint8Array(await file.arrayBuffer()),
      name: file.name,
    })),
  );

  persistSelectionMetadata(files, wadMode.value);
  syncSelectionSummary();
  renderPersistedSelection();
  setStatus('Ready', 'ready');
  appendLog('info', `Prepared ${files.length} uploaded file(s) for the next launch.`);
}

function updateButtons() {
  fullscreenButton.disabled = !state.running;
  pointerButton.disabled = !state.running;
  playButton.disabled = state.running;
}

async function launchEngine() {
  if (state.running) {
    return;
  }

  const selection = classifyUploads(state.cachedUploads, wadMode.value);
  const args = buildCliArgs(selection);
  state.sessionId = globalThis.crypto.randomUUID();
  state.telemetryQueue = [];
  aiBridgeState.decisions.clear();
  aiBridgeState.inflight.clear();

  setStatus('Booting', 'busy');
  appendLog('info', `Launching Chocolate Doom with args: ${args.join(' ')}`);
  canvasOverlay.hidden = true;

  try {
    // The Emscripten output lives in /public, so it must be loaded via the
    // browser's native dynamic import rather than Vite's source graph.
    const { default: createDoomModule } = await (0, eval)(`import(${JSON.stringify(ENGINE_MODULE_URL)})`);

    const module = await createDoomModule({
      canvas,
      keyboardListeningElement: canvas,
      locateFile: (path) => `${ENGINE_FILE_BASE}${path}`,
      noInitialRun: true,
      onAbort: (reason) => {
        appendLog('error', `Engine aborted: ${reason}`);
        setStatus('Error', 'error');
      },
      preRun: [
        (runtimeModule) => {
          prepareVirtualFilesystem(runtimeModule, selection);
        },
      ],
      print: (text) => appendLog('info', text),
      printErr: (text) => appendLog('error', text),
    });

    state.engine = module;
    syncAiMode({ log: false });

    try {
      module.callMain(args);
    } catch (error) {
      const message = String(error ?? '');

      if (!message.includes('unwind') && !message.includes('SimulateInfiniteLoop')) {
        throw error;
      }
    }

    state.running = true;
    canvas.focus();
    setStatus('Running', 'running');
    updateButtons();
    appendLog('info', 'Engine initialized successfully.');
  } catch (error) {
    canvasOverlay.hidden = false;
    setStatus('Error', 'error');
    appendLog('error', `Failed to start engine: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
  }
}

async function enterFullscreen() {
  if (!state.running) {
    return;
  }

  await canvasShell.requestFullscreen?.();
  canvas.focus();
}

async function lockPointer() {
  if (!state.running) {
    return;
  }

  try {
    await canvas.requestPointerLock?.();
    canvas.focus();
  } catch (error) {
    appendLog('info', `Pointer lock unavailable in this browser: ${error instanceof Error ? error.message : String(error)}`);
  }
}

playButton.addEventListener('click', launchEngine);
fullscreenButton.addEventListener('click', enterFullscreen);
pointerButton.addEventListener('click', lockPointer);
clearLogButton.addEventListener('click', () => {
  logOutput.textContent = '';
});
wadMode.addEventListener('change', syncSelectionSummary);
wadInput.addEventListener('change', async (event) => {
  const files = [...(event.target.files ?? [])];
  await cacheUploads(files);
});
aiMode.addEventListener('change', () => syncAiMode());
aiProvider.addEventListener('change', () => {
  if (aiProvider.value === 'backend') {
    if (aiMode.value === 'external') {
      state.sessionId ||= globalThis.crypto.randomUUID();
    }
    connectAiBackend();
  } else {
    void finishAiSession().finally(() => {
      disconnectAiBackend();
      setBackendStatus('Local mock selected');
    });
  }
  appendLog('info', `[AI BRIDGE] decision source set to ${aiProvider.value}.`);
});

window.addEventListener('pagehide', () => {
  if (!state.sessionId || aiBridgeState.socket?.readyState !== WebSocket.OPEN) {
    return;
  }

  flushTelemetryQueue();
  aiBridgeState.socket.send(JSON.stringify({
    type: 'session_end',
    session_id: state.sessionId,
  }));
});

canvas.addEventListener('click', () => {
  if (state.running) {
    canvas.focus();
  }
});

setStatus('Ready');
updateButtons();
syncSelectionSummary();
renderPersistedSelection();
syncAiMode({ log: false });
appendLog('info', 'Browser shell ready. Click Play to boot Freedoom.');
