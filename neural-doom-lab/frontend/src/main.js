import './styles.css';
import { resolveAiWebSocketUrl } from './ai-url.js';
import {
  findPlayableArchitecture,
  formatTopology,
  isPlayableArchitecture,
  parseTopology,
} from './neural-lab.js';
import {
  createAiMetrics,
  formatAiMetrics,
  recordEngineOffer,
  recordEngineResult,
  recordFallback,
  recordInvalidSqlResponse,
  recordOpportunity,
  recordSqlDecision,
  snapshotAiMetrics,
} from './ai-metrics.js';

const STORAGE_KEY = 'doomwasm.selection';
const DEFAULT_IWAD_PATH = '/iwads/freedoom2.wad';
const DEFAULT_IWAD_NAME = 'freedoom2.wad';
const ENGINE_MODULE_URL = `${import.meta.env.BASE_URL}engine/chocolate-doom.js`;
const ENGINE_FILE_BASE = `${import.meta.env.BASE_URL}engine/`;
const AI_WEBSOCKET_URL = resolveAiWebSocketUrl(
  window.location,
  import.meta.env.VITE_AI_WEBSOCKET_URL,
);
const AI_HTTP_BASE_URL = import.meta.env.VITE_AI_HTTP_URL
  || `${window.location.protocol}//${window.location.hostname}:8000`;
const NEURAL_LAB_STORAGE_KEY = 'neural-doom-lab.architecture';
const NEURAL_LAB_GENOME_STORAGE_KEY = 'neural-doom-lab.game-genome';
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
        <p class="note">A fonte só é usada no EXTERNAL_AI; ORIGINAL_AI continua no engine original.</p>
      </section>

      <section class="panel connection-panel">
        <h2><span class="panel-icon" aria-hidden="true">⌁</span>Conexão</h2>
        <div class="connection-status" data-status="disconnected">
          <span class="signal-dot" aria-hidden="true"></span>
          <div><small>WebSocket bridge</small><strong id="ai-debug-backend">Disconnected</strong></div>
        </div>
        <code>${AI_WEBSOCKET_URL}</code>
      </section>

      <section class="panel npc-panel" id="npc-status">
        <h2><span class="panel-icon" aria-hidden="true">☠</span>NPC atual</h2>
        <dl class="ai-debug" id="ai-debug">
          <div><dt>Mode</dt><dd id="ai-debug-mode">ORIGINAL_AI</dd></div>
          <div><dt>NPC</dt><dd id="ai-debug-npc">—</dd></div>
          <div><dt>State</dt><dd id="ai-debug-state">—</dd></div>
          <div><dt>Action</dt><dd id="ai-debug-action">Original engine</dd></div>
          <div><dt>Resumo da sessão</dt><dd id="ai-debug-metrics">Aguardando partida com MySQL neural</dd></div>
        </dl>
      </section>

      <section class="utility-panel controls-panel" id="utilities">
        <h2><span class="panel-icon" aria-hidden="true">⌨</span>Controles</h2>
        <div class="controls">
          <p><span>Avançar / recuar</span><strong>↑ / ↓</strong></p>
          <p><span>Girar</span><strong>← / →</strong></p>
          <p><span>Atirar</span><strong>Ctrl</strong></p>
          <p><span>Usar / abrir</span><strong>Espaço</strong></p>
          <p><span>Correr</span><strong>Shift</strong></p>
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

    <details class="neural-lab panel" id="neural-lab">
      <summary class="neural-lab-summary">
        <span><span class="panel-icon" aria-hidden="true">◉</span>Laboratório neural interativo</span>
        <small id="lab-status">Recolhido — sem consultas em segundo plano</small>
      </summary>
      <div class="lab-layout">
        <section class="lab-card">
          <div class="lab-recommendation" id="lab-recommendation">
            <h3>Configuração sugerida para avaliação</h3>
            <p><strong>Modo:</strong> EXTERNAL_AI · <strong>Fonte:</strong> MySQL neural via backend</p>
            <p><strong>Candidata:</strong> 4 → 32 → 4, geração 1 <span id="lab-recommended-candidate">consultando catálogo local…</span></p>
            <button class="text-button" id="lab-apply-recommended" type="button" disabled>Usar candidata</button>
            <p><strong>Menor custo:</strong> 4 → 6 → 4, geração 1 <span id="lab-recommended-alternative">consultando catálogo local…</span></p>
            <button class="text-button" id="lab-apply-alternative" type="button" disabled>Usar alternativa</button>
            <p class="lab-note">Referência atual: Freedoom 2 MAP01, skill 2. Candidatas experimentais; os dados disponíveis não comprovam superioridade entre gerações ou arquiteturas.</p>
          </div>
          <h3>Arquitetura utilizável na próxima sessão</h3>
          <label class="field"><span>Arquitetura</span><select id="lab-architecture-select" disabled><option>Conecte o MySQL para listar</option></select></label>
          <p class="lab-summary-copy" id="lab-architecture-summary">Somente arquiteturas com população/geração que o SQL aceita aparecem aqui.</p>
          <div class="lab-layers" id="lab-layer-list"><p class="lab-empty">Abra o painel para consultar arquiteturas do MySQL.</p></div>
          <div class="lab-inspect-selectors">
            <label class="field"><span>Geração para inspeção</span><select id="lab-generation-select" disabled></select></label>
            <label class="field"><span>Genoma para inspeção</span><select id="lab-genome-select" disabled></select></label>
          </div>
          <button class="text-button lab-pin-genome-button" id="lab-pin-genome" type="button" disabled>Usar genoma selecionado na próxima partida</button>
          <p class="lab-note" id="lab-genome-selection-note">Sem genoma fixado, o MySQL distribui o roster da geração utilizável. Uma escolha fixada vale para a sessão inteira e não altera pesos.</p>
        </section>

        <section class="lab-card">
          <h3>Criar topologia sem tocar nas existentes</h3>
          <label class="field"><span>Nome único</span><input id="lab-new-name" maxlength="50" autocomplete="off" placeholder="minha_rede_4_32_4" /></label>
          <label class="field"><span>Camadas (4 entradas e 4 saídas fixas)</span><input id="lab-new-topology" value="4, 32, 4" inputmode="numeric" /></label>
          <label class="field"><span>Ativação das camadas ocultas</span><select id="lab-hidden-activation"><option value="relu">ReLU</option><option value="sigmoid">Sigmoid</option><option value="tanh">Tanh</option></select></label>
          <div class="lab-parameter-count" id="lab-parameter-count">4 → 32 → 4 · 0 pesos · 0 biases · 0 parâmetros</div>
          <button class="button button-primary lab-button" id="lab-create-architecture" type="button">Criar arquitetura</button>
          <div class="lab-divider"></div>
          <h3>População inicial isolada</h3>
          <label class="field"><span>Arquitetura vazia para receber a população</span><select id="lab-population-target" disabled><option>Nenhuma arquitetura vazia</option></select></label>
          <div class="lab-layers lab-population-target-details" id="lab-population-target-details"><p class="lab-empty">Crie uma topologia para escolher uma população inicial.</p></div>
          <label class="field"><span>Indivíduos (2–100)</span><input id="lab-population-size" type="number" min="2" max="100" value="4" /></label>
          <label class="field"><span>Semente reproduzível (0–4294967295)</span><input id="lab-population-seed" type="number" min="0" max="4294967295" value="20261031" /></label>
          <button class="button lab-button" id="lab-create-population" type="button" disabled>Inicializar população vazia</button>
          <p class="lab-note">Uma população existente nunca é substituída. Criação administrativa só aceita origem local autorizada e chama as procedures já instaladas.</p>
        </section>

        <section class="lab-card lab-live-card">
          <h3>Inferência real do jogo</h3>
          <dl class="lab-live-metrics">
            <div><dt>Decisão MySQL</dt><dd id="lab-live-action">Aguardando NPC</dd></div>
            <div><dt>NPC / genoma / geração</dt><dd id="lab-live-identity">—</dd></div>
            <div><dt>Aplicação no engine</dt><dd id="lab-live-engine-result">Aguardando retorno</dd></div>
            <div><dt>SQL / banco</dt><dd id="lab-live-latency">—</dd></div>
            <div><dt>Round trip WebSocket</dt><dd id="lab-live-rtt">—</dd></div>
            <div><dt>Última execução SQL</dt><dd id="lab-live-run">—</dd></div>
          </dl>
          <label class="field"><span>Camada de ativações (valores reais persistidos pelo SQL)</span><select id="lab-inspection-layer" disabled></select></label>
          <div class="lab-neuron-list" id="lab-activations"><p class="lab-empty">Abra EXTERNAL_AI e aguarde uma decisão SQL para inspecionar.</p></div>
          <div class="lab-page-controls">
            <button class="text-button" id="lab-activation-previous" type="button" disabled>← Anterior</button>
            <span id="lab-activation-page">—</span>
            <button class="text-button" id="lab-activation-next" type="button" disabled>Próxima →</button>
          </div>
          <div class="lab-divider"></div>
          <h3>Pesos de entrada e bias do neurônio selecionado</h3>
          <button class="text-button lab-live-genome-button" id="lab-use-live-genome" type="button" disabled>Usar genoma da última inferência</button>
          <div class="lab-weight-controls">
            <label class="field"><span>Camada alvo</span><select id="lab-weight-layer" disabled></select></label>
            <label class="field"><span>Posição do neurônio</span><input id="lab-weight-target" type="number" min="0" value="0" /></label>
            <button class="button" id="lab-load-weights" type="button">Consultar pesos</button>
          </div>
          <p class="lab-bias-value" id="lab-weight-bias">Bias do neurônio selecionado: —</p>
          <div class="lab-weight-list" id="lab-weights"><p class="lab-empty">Selecione uma geração e um genoma para consultar conexões paginadas.</p></div>
          <div class="lab-page-controls">
            <button class="text-button" id="lab-weight-previous" type="button" disabled>← Anterior</button>
            <span id="lab-weight-page">—</span>
            <button class="text-button" id="lab-weight-next" type="button" disabled>Próxima →</button>
          </div>
        </section>
      </div>
    </details>

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
const aiDebugMetrics = document.querySelector('#ai-debug-metrics');
const aiDebugBackend = document.querySelector('#ai-debug-backend');
const connectionStatus = document.querySelector('.connection-status');
const clearLogButton = document.querySelector('#clear-log-button');
const neuralLabPanel = document.querySelector('#neural-lab');
const labStatus = document.querySelector('#lab-status');
const labArchitectureSelect = document.querySelector('#lab-architecture-select');
const labArchitectureSummary = document.querySelector('#lab-architecture-summary');
const labRecommendedCandidate = document.querySelector('#lab-recommended-candidate');
const labRecommendedAlternative = document.querySelector('#lab-recommended-alternative');
const labApplyRecommended = document.querySelector('#lab-apply-recommended');
const labApplyAlternative = document.querySelector('#lab-apply-alternative');
const labLayerList = document.querySelector('#lab-layer-list');
const labGenerationSelect = document.querySelector('#lab-generation-select');
const labGenomeSelect = document.querySelector('#lab-genome-select');
const labPinGenome = document.querySelector('#lab-pin-genome');
const labGenomeSelectionNote = document.querySelector('#lab-genome-selection-note');
const labNewName = document.querySelector('#lab-new-name');
const labNewTopology = document.querySelector('#lab-new-topology');
const labHiddenActivation = document.querySelector('#lab-hidden-activation');
const labParameterCount = document.querySelector('#lab-parameter-count');
const labCreateArchitecture = document.querySelector('#lab-create-architecture');
const labPopulationSize = document.querySelector('#lab-population-size');
const labPopulationSeed = document.querySelector('#lab-population-seed');
const labCreatePopulation = document.querySelector('#lab-create-population');
const labPopulationTarget = document.querySelector('#lab-population-target');
const labPopulationTargetDetails = document.querySelector('#lab-population-target-details');
const labLiveAction = document.querySelector('#lab-live-action');
const labLiveIdentity = document.querySelector('#lab-live-identity');
const labLiveEngineResult = document.querySelector('#lab-live-engine-result');
const labLiveLatency = document.querySelector('#lab-live-latency');
const labLiveRtt = document.querySelector('#lab-live-rtt');
const labLiveRun = document.querySelector('#lab-live-run');
const labInspectionLayer = document.querySelector('#lab-inspection-layer');
const labActivations = document.querySelector('#lab-activations');
const labActivationPrevious = document.querySelector('#lab-activation-previous');
const labActivationNext = document.querySelector('#lab-activation-next');
const labActivationPage = document.querySelector('#lab-activation-page');
const labWeightLayer = document.querySelector('#lab-weight-layer');
const labWeightTarget = document.querySelector('#lab-weight-target');
const labLoadWeights = document.querySelector('#lab-load-weights');
const labWeightBias = document.querySelector('#lab-weight-bias');
const labWeights = document.querySelector('#lab-weights');
const labWeightPrevious = document.querySelector('#lab-weight-previous');
const labWeightNext = document.querySelector('#lab-weight-next');
const labWeightPage = document.querySelector('#lab-weight-page');
const labUseLiveGenome = document.querySelector('#lab-use-live-genome');

function readPinnedGenomePreference() {
  try {
    const value = JSON.parse(localStorage.getItem(NEURAL_LAB_GENOME_STORAGE_KEY) || 'null');
    return value && typeof value.architectureName === 'string' && Number.isInteger(Number(value.genomeId))
      ? { architectureName: value.architectureName, genomeId: Number(value.genomeId) }
      : null;
  } catch {
    return null;
  }
}

const storedGenomePreference = readPinnedGenomePreference();

const neuralLabState = {
  architectures: [],
  configuredDefault: null,
  layers: [],
  genomes: [],
  selectedArchitectureId: null,
  selectedArchitectureName: localStorage.getItem(NEURAL_LAB_STORAGE_KEY) || null,
  selectedGeneration: null,
  selectedGenomeId: null,
  selectedGameGenomeId: storedGenomePreference?.genomeId ?? null,
  selectedGameGenomeArchitecture: storedGenomePreference?.architectureName ?? null,
  populationTargetName: null,
  recommendedCandidate: null,
  recommendedAlternative: null,
  latestDecision: null,
  liveGenome: null,
  activationOffset: 0,
  activationTotal: 0,
  weightOffset: 0,
  weightTotal: 0,
  refreshTimer: null,
  activationRequestInFlight: false,
  latestEngineOutcome: 'Aguardando retorno',
  loading: false,
};

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

async function labRequest(path, options = {}) {
  const response = await fetch(new URL(`/api/lab${path}`, AI_HTTP_BASE_URL), {
    ...options,
    cache: 'no-store',
    credentials: 'omit',
    headers: {
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...options.headers,
    },
  });
  let payload = {};
  try {
    payload = await response.json();
  } catch {
    payload = {};
  }
  if (!response.ok) {
    throw new Error(payload.detail || `HTTP ${response.status}`);
  }
  return payload;
}

function setLabStatus(message, tone = 'muted') {
  labStatus.textContent = message;
  labStatus.dataset.tone = tone;
}

function addLabOption(select, value, label) {
  const option = document.createElement('option');
  option.value = String(value);
  option.textContent = label;
  select.append(option);
}

function selectedLabArchitecture() {
  return neuralLabState.architectures.find(
    (architecture) => String(architecture.architecture_id) === String(neuralLabState.selectedArchitectureId),
  ) ?? null;
}

function findRecommendation(topology) {
  const architecture = findPlayableArchitecture(neuralLabState.architectures, topology);
  return Number(architecture?.playable_generation) === 1 ? architecture : null;
}

function updateLabRecommendations() {
  const candidate = findRecommendation([4, 32, 4]);
  const alternative = findRecommendation([4, 6, 4]);
  neuralLabState.recommendedCandidate = candidate;
  neuralLabState.recommendedAlternative = alternative;
  labRecommendedCandidate.textContent = candidate
    ? `${candidate.architecture_name} · ${candidate.genome_count} genomas utilizáveis`
    : 'não disponível no catálogo com geração 1 utilizável';
  labRecommendedAlternative.textContent = alternative
    ? `${alternative.architecture_name} · ${alternative.genome_count} genomas utilizáveis`
    : 'não disponível no catálogo com geração 1 utilizável';
  labApplyRecommended.disabled = !candidate || aiBridgeState.sessionArchitectureLocked;
  labApplyAlternative.disabled = !alternative || aiBridgeState.sessionArchitectureLocked;
}

function renderPopulationTargetLayers(layers) {
  labPopulationTargetDetails.replaceChildren();
  if (!layers.length) {
    const empty = document.createElement('p');
    empty.className = 'lab-empty';
    empty.textContent = 'A arquitetura vazia não tem camadas consultáveis.';
    labPopulationTargetDetails.append(empty);
    return;
  }
  for (const layer of layers) {
    const row = document.createElement('div');
    row.className = 'lab-layer-row';
    const name = document.createElement('strong');
    name.textContent = `${layer.layer_order}: ${String(layer.layer_type).toUpperCase()}`;
    const count = document.createElement('span');
    count.textContent = `${layer.neuron_count} neurônios`;
    const detail = document.createElement('small');
    detail.textContent = layer.io_names || layer.activations || 'ativações configuráveis';
    row.append(name, count, detail);
    labPopulationTargetDetails.append(row);
  }
}

async function loadPopulationTargetDetails() {
  const architecture = neuralLabState.architectures.find(
    (item) => item.architecture_name === neuralLabState.populationTargetName,
  );
  if (!architecture) return;
  try {
    const payload = await labRequest(`/architectures/${architecture.architecture_id}/layers`);
    renderPopulationTargetLayers(payload.layers ?? []);
    labCreatePopulation.disabled = Number(architecture.genome_count) > 0;
    labCreatePopulation.textContent = Number(architecture.genome_count) > 0
      ? 'População existente preservada'
      : 'Inicializar população vazia';
  } catch (error) {
    labPopulationTargetDetails.textContent = `Não foi possível consultar as camadas: ${error.message}`;
    labCreatePopulation.disabled = true;
  }
}

function updatePopulationTargets(preferredName = null) {
  const emptyArchitectures = neuralLabState.architectures.filter(
    (architecture) => Number(architecture.genome_count) === 0,
  );
  labPopulationTarget.replaceChildren();
  if (!emptyArchitectures.length) {
    addLabOption(labPopulationTarget, '', 'Nenhuma arquitetura sem população');
    labPopulationTarget.disabled = true;
    neuralLabState.populationTargetName = null;
    labCreatePopulation.disabled = true;
    labCreatePopulation.textContent = 'Nenhuma arquitetura vazia';
    labPopulationTargetDetails.innerHTML = '<p class="lab-empty">Crie uma nova arquitetura para inicializar uma população sem tocar nas existentes.</p>';
    return;
  }
  for (const architecture of emptyArchitectures) {
    addLabOption(labPopulationTarget, architecture.architecture_name,
      `${architecture.architecture_name} · ${architecture.topology} · sem genomas`);
  }
  const selected = emptyArchitectures.find((item) => item.architecture_name === preferredName)
    ?? emptyArchitectures.find((item) => item.architecture_name === neuralLabState.populationTargetName)
    ?? emptyArchitectures[0];
  neuralLabState.populationTargetName = selected.architecture_name;
  labPopulationTarget.value = selected.architecture_name;
  labPopulationTarget.disabled = false;
  void loadPopulationTargetDetails();
}

function updateGameGenomePinControl() {
  const architecture = selectedLabArchitecture();
  const usableGeneration = Number(architecture?.playable_generation);
  const selectedGenome = neuralLabState.genomes.find(
    (genome) => String(genome.genome_id) === String(neuralLabState.selectedGenomeId),
  );
  const compatible = Boolean(
    selectedGenome
    && Number(selectedGenome.generation) === usableGeneration
    && isPlayableArchitecture(architecture)
    && !aiBridgeState.sessionArchitectureLocked,
  );
  labPinGenome.disabled = !compatible;
  const pinnedHere = neuralLabState.selectedGameGenomeArchitecture === architecture?.architecture_name;
  if (pinnedHere && neuralLabState.selectedGameGenomeId) {
    labPinGenome.textContent = !aiBridgeState.sessionArchitectureLocked
      && String(neuralLabState.selectedGameGenomeId) === String(neuralLabState.selectedGenomeId)
      ? 'Remover genoma fixado para a próxima partida'
      : 'Usar genoma selecionado na próxima partida';
    labGenomeSelectionNote.textContent = aiBridgeState.sessionArchitectureLocked
      ? `A sessão atual está travada. O genoma #${neuralLabState.selectedGameGenomeId} só será enviado na próxima partida.`
      : `Genoma #${neuralLabState.selectedGameGenomeId} fixado para ${architecture.architecture_name}. A próxima sessão manterá essa seleção até o encerramento.`;
  } else {
    labPinGenome.textContent = 'Usar genoma selecionado na próxima partida';
    labGenomeSelectionNote.textContent = compatible
      ? `A geração ${usableGeneration} é a que o SQL aceita agora. Fixe um genoma dessa geração ou deixe o banco balancear o roster.`
      : 'Genomas de gerações históricas podem ser inspecionados; só a geração que o SQL aceita pode ser fixada para jogar.';
  }
}

async function applyRecommendedArchitecture(architecture) {
  if (!architecture || !isPlayableArchitecture(architecture) || aiBridgeState.sessionArchitectureLocked) return;
  labArchitectureSelect.value = architecture.architecture_name;
  neuralLabState.selectedArchitectureId = architecture.architecture_id;
  neuralLabState.selectedArchitectureName = architecture.architecture_name;
  neuralLabState.selectedGeneration = Number(architecture.playable_generation);
  neuralLabState.activationOffset = 0;
  neuralLabState.weightOffset = 0;
  if (neuralLabState.selectedGameGenomeArchitecture !== architecture.architecture_name) {
    neuralLabState.selectedGameGenomeId = null;
    neuralLabState.selectedGameGenomeArchitecture = null;
    localStorage.removeItem(NEURAL_LAB_GENOME_STORAGE_KEY);
  }
  localStorage.setItem(NEURAL_LAB_STORAGE_KEY, architecture.architecture_name);
  await loadLabArchitectureDetails();
  aiProvider.value = 'backend';
  aiMode.value = 'external';
  syncAiMode();
}

function renderArchitectureLayers() {
  labLayerList.replaceChildren();
  if (!neuralLabState.layers.length) {
    const empty = document.createElement('p');
    empty.className = 'lab-empty';
    empty.textContent = 'Esta arquitetura ainda não tem camadas consultáveis.';
    labLayerList.append(empty);
    return;
  }

  for (const layer of neuralLabState.layers) {
    const row = document.createElement('div');
    row.className = 'lab-layer-row';
    const name = document.createElement('strong');
    name.textContent = `${layer.layer_order}: ${String(layer.layer_type).toUpperCase()}`;
    const count = document.createElement('span');
    count.textContent = `${layer.neuron_count} neurônios`;
    const detail = document.createElement('small');
    detail.textContent = layer.io_names || layer.activations || 'ativações configuráveis';
    row.append(name, count, detail);
    labLayerList.append(row);
  }
}

function setLabLayerOptions(layers) {
  for (const select of [labInspectionLayer, labWeightLayer]) {
    select.replaceChildren();
  }
  for (const layer of layers) {
    addLabOption(labInspectionLayer, layer.layer_order,
      `${layer.layer_order} · ${layer.layer_type} · ${layer.neuron_count} neurônios`);
    if (layer.layer_order > 0) {
      addLabOption(labWeightLayer, layer.layer_order,
        `${layer.layer_order} · ${layer.layer_type} · ${layer.neuron_count} neurônios`);
    }
  }
  const outputLayer = layers.at(-1);
  if (outputLayer) {
    labInspectionLayer.value = String(outputLayer.layer_order);
    labWeightLayer.value = String(Math.max(1, outputLayer.layer_order));
  }
  labInspectionLayer.disabled = !layers.length;
  labWeightLayer.disabled = layers.length < 2 || !neuralLabState.selectedGenomeId;
}

async function loadLabGenomes() {
  const architecture = selectedLabArchitecture();
  if (!architecture) return;
  const latest = Number.isInteger(Number(architecture.latest_generation))
    ? Number(architecture.latest_generation)
    : 0;
  const playableGeneration = Number(architecture.playable_generation);
  const generationCount = Math.max(0, Number(architecture.generation_count) || 0);
  const generations = Array.from({ length: Math.min(generationCount, latest + 1, 256) }, (_, index) => index);
  labGenerationSelect.replaceChildren();
  if (!generations.length) generations.push(0);
  for (const generation of generations) addLabOption(labGenerationSelect, generation, `Geração ${generation}`);
  const previousGeneration = neuralLabState.selectedGeneration;
  neuralLabState.selectedGeneration = generations.includes(previousGeneration)
    ? previousGeneration
    : (Number.isInteger(playableGeneration) ? playableGeneration : latest);
  if (!generations.includes(latest)) {
    addLabOption(labGenerationSelect, latest, `Geração ${latest}`);
  }
  labGenerationSelect.value = String(neuralLabState.selectedGeneration);
  labGenerationSelect.disabled = Number(architecture.genome_count) <= 0;
  labGenomeSelect.replaceChildren();
  neuralLabState.genomes = [];
  neuralLabState.selectedGenomeId = null;

  if (Number(architecture.genome_count) <= 0) {
    addLabOption(labGenomeSelect, '', 'Sem população inicial');
    labGenomeSelect.disabled = true;
    updateGameGenomePinControl();
    return;
  }

  const payload = await labRequest(
    `/architectures/${architecture.architecture_id}/genomes?generation=${neuralLabState.selectedGeneration}&limit=100&offset=0`,
  );
  neuralLabState.genomes = payload.genomes ?? [];
  for (const genome of neuralLabState.genomes) {
    const evaluationCount = Number(genome.real_evaluation_count) || 0;
    addLabOption(labGenomeSelect, genome.genome_id,
      `#${genome.genome_id} · fitness ${Number(genome.fitness).toFixed(4)} · ${evaluationCount} avaliações v2 persistidas`);
  }
  labGenomeSelect.disabled = !neuralLabState.genomes.length;
  const pinnedGenome = neuralLabState.genomes.find((genome) => (
    neuralLabState.selectedGameGenomeArchitecture === architecture.architecture_name
    && String(genome.genome_id) === String(neuralLabState.selectedGameGenomeId)
  ));
  neuralLabState.selectedGenomeId = pinnedGenome?.genome_id ?? neuralLabState.genomes[0]?.genome_id ?? null;
  if (neuralLabState.selectedGenomeId !== null) {
    labGenomeSelect.value = String(neuralLabState.selectedGenomeId);
  }
  labWeightLayer.disabled = !neuralLabState.selectedGenomeId || neuralLabState.layers.length < 2;
  updateGameGenomePinControl();
}

async function loadLabArchitectureDetails() {
  const architecture = selectedLabArchitecture();
  if (!architecture) return;
  neuralLabState.selectedArchitectureId = architecture.architecture_id;
  neuralLabState.selectedArchitectureName = architecture.architecture_name;
  const genomeCount = Number(architecture.genome_count) || 0;
  const populationStatus = `${genomeCount} genomas · ${architecture.generation_count} gerações · SQL aceita geração ${architecture.playable_generation}`;
  labArchitectureSummary.textContent = `${architecture.architecture_name} · ${architecture.topology} · ${architecture.parameter_count ?? (Number(architecture.weight_count) + Number(architecture.bias_count))} parâmetros · ${populationStatus}`;
  try {
    const layers = await labRequest(`/architectures/${architecture.architecture_id}/layers`);
    neuralLabState.layers = layers.layers ?? [];
    renderArchitectureLayers();
    setLabLayerOptions(neuralLabState.layers);
    await loadLabGenomes();
    if (neuralLabState.latestDecision && neuralLabState.latestDecision.architecture_name === architecture.architecture_name) {
      scheduleLabRunRefresh(0);
    }
    await loadLabWeights();
    setLabStatus(`${neuralLabState.architectures.length} arquiteturas · MySQL conectado`, 'ok');
  } catch (error) {
    setLabStatus(`MySQL indisponível: ${error.message}`, 'error');
  }
}

async function loadLabArchitectures(preferredName = null) {
  if (neuralLabState.loading) return;
  neuralLabState.loading = true;
  setLabStatus('Consultando procedures SQL…', 'pending');
  try {
    const payload = await labRequest('/architectures');
    neuralLabState.architectures = payload.architectures ?? [];
    neuralLabState.configuredDefault = payload.configured_default ?? null;
    updateLabRecommendations();
    updatePopulationTargets(preferredName);
    labArchitectureSelect.replaceChildren();
    const playableArchitectures = neuralLabState.architectures.filter(isPlayableArchitecture);
    if (!playableArchitectures.length) {
      addLabOption(labArchitectureSelect, '', 'Nenhuma arquitetura com geração utilizável');
      labArchitectureSelect.disabled = true;
      neuralLabState.selectedArchitectureName = null;
      neuralLabState.selectedArchitectureId = null;
      labArchitectureSummary.textContent = 'O catálogo não tem população compatível para iniciar uma sessão neural.';
      labLayerList.innerHTML = '<p class="lab-empty">Crie uma topologia, inicialize uma população e atualize o catálogo.</p>';
      updateGameGenomePinControl();
      setLabStatus('Nenhuma população utilizável no SQL', 'error');
      return;
    }
    for (const architecture of playableArchitectures) {
      const genomeCount = Number(architecture.genome_count) || 0;
      addLabOption(labArchitectureSelect, architecture.architecture_name,
        `${architecture.architecture_name} · ${architecture.topology} · geração ${architecture.playable_generation} · ${genomeCount} genomas`);
    }
    const activeSessionArchitecture = aiBridgeState.sessionArchitectureLocked
      ? neuralLabState.latestDecision?.architectureName || neuralLabState.selectedArchitectureName
      : null;
    const requested = activeSessionArchitecture
      || preferredName
      || neuralLabState.selectedArchitectureName
      || neuralLabState.configuredDefault;
    const selected = playableArchitectures.find((architecture) => architecture.architecture_name === requested)
      ?? neuralLabState.recommendedCandidate
      ?? neuralLabState.recommendedAlternative
      ?? playableArchitectures[0];
    neuralLabState.selectedArchitectureName = selected.architecture_name;
    neuralLabState.selectedArchitectureId = selected.architecture_id;
    labArchitectureSelect.value = selected.architecture_name;
    labArchitectureSelect.disabled = aiBridgeState.sessionArchitectureLocked;
    if (!aiBridgeState.sessionArchitectureLocked) {
      localStorage.setItem(NEURAL_LAB_STORAGE_KEY, selected.architecture_name);
    }
    await loadLabArchitectureDetails();
  } catch (error) {
    setLabStatus(`MySQL indisponível: ${error.message}`, 'error');
    labArchitectureSummary.textContent = 'Não foi possível consultar as arquiteturas. Confirme backend, MySQL e o schema local.';
  } finally {
    neuralLabState.loading = false;
  }
}

function renderLabActivations(rows) {
  labActivations.replaceChildren();
  if (!rows.length) {
    const empty = document.createElement('p');
    empty.className = 'lab-empty';
    empty.textContent = 'Esta camada não possui ativações neste run.';
    labActivations.append(empty);
    return;
  }
  const first = rows[0];
  neuralLabState.liveGenome = {
    architectureId: first.architecture_id,
    architectureName: first.architecture_name,
    genomeId: first.genome_id,
    generation: first.generation,
  };
  labUseLiveGenome.disabled = false;
  labLiveIdentity.textContent = `NPC ${first.npc_id} · genoma #${first.genome_id} · geração ${first.generation} · ${first.architecture_name}`;
  labLiveRun.textContent = `#${first.run_id} · ${new Date(first.created_at).toLocaleTimeString()}`;
  neuralLabState.activationTotal = Number(first.layer_total_neurons) || rows.length;
  const pageCount = Math.max(1, Math.ceil(neuralLabState.activationTotal / 128));
  const page = Math.floor(neuralLabState.activationOffset / 128) + 1;
  labActivationPage.textContent = `Página ${page}/${pageCount} · ${neuralLabState.activationTotal} neurônios`;
  labActivationPrevious.disabled = neuralLabState.activationOffset <= 0;
  labActivationNext.disabled = neuralLabState.activationOffset + rows.length >= neuralLabState.activationTotal;

  const maxMagnitude = Math.max(0.000001, ...rows.map((row) => Math.abs(Number(row.activation) || 0)));
  for (const activation of rows) {
    const row = document.createElement('div');
    row.className = 'lab-neuron-row';
    const label = document.createElement('span');
    label.textContent = `${activation.io_name || `N${activation.neuron_position}`} · ${activation.neuron_position}`;
    const bar = document.createElement('span');
    bar.className = `lab-activation-bar${Number(activation.activation) < 0 ? ' negative' : ''}`;
    bar.style.setProperty('--activation-size', `${Math.max(1, Math.min(100, Math.abs(Number(activation.activation)) / maxMagnitude * 100))}%`);
    const value = document.createElement('code');
    value.textContent = Number(activation.activation).toPrecision(7);
    row.append(label, bar, value);
    labActivations.append(row);
  }
}

function renderLatestDecisionSummary() {
  const decision = neuralLabState.latestDecision;
  if (!neuralLabPanel.open) return;
  if (!decision) {
    labLiveEngineResult.textContent = neuralLabState.latestEngineOutcome;
    return;
  }
  labLiveAction.textContent = `${decision.action} · confiança ${Number(decision.confidence).toFixed(4)}`;
  labLiveEngineResult.textContent = neuralLabState.latestEngineOutcome;
  labLiveLatency.textContent = `${Number(decision.mysqlInferenceMs).toFixed(2)} ms CALL MySQL · ${Number(decision.databaseRoundTripMs).toFixed(2)} ms backend + banco`;
  labLiveRtt.textContent = `${Number(decision.websocketRttMs).toFixed(2)} ms browser ↔ backend`;
  labLiveRun.textContent = `run #${decision.runId} · aguardando ativações persistidas`;
  labLiveIdentity.textContent = `NPC ${decision.npcId} · ${decision.architectureName || 'arquitetura do backend'}`;
}

async function refreshLabRun() {
  if (!neuralLabPanel.open || !neuralLabState.latestDecision || document.hidden
      || neuralLabState.activationRequestInFlight) return;
  const layerOrder = Number(labInspectionLayer.value);
  if (!Number.isInteger(layerOrder)) return;
  const runId = neuralLabState.latestDecision.runId;
  neuralLabState.activationRequestInFlight = true;
  try {
    const payload = await labRequest(`/runs/${runId}/activations?layer_order=${layerOrder}&limit=128&offset=${neuralLabState.activationOffset}`);
    if (neuralLabState.latestDecision?.runId === runId) {
      renderLabActivations(payload.activations ?? []);
    }
  } catch (error) {
    if (error.message !== 'run_or_layer_not_found') {
      setLabStatus(`Inspeção de ativações: ${error.message}`, 'error');
    }
  } finally {
    neuralLabState.activationRequestInFlight = false;
  }
}

function scheduleLabRunRefresh(delay = 900) {
  if (!neuralLabPanel.open || !neuralLabState.latestDecision) return;
  if (neuralLabState.refreshTimer) return;
  neuralLabState.refreshTimer = window.setTimeout(() => {
    neuralLabState.refreshTimer = null;
    void refreshLabRun();
  }, delay);
}

async function loadLabWeights() {
  const genomeId = neuralLabState.selectedGenomeId;
  const layerOrder = Number(labWeightLayer.value);
  const targetPosition = Number(labWeightTarget.value);
  if (!neuralLabPanel.open || !genomeId || !Number.isInteger(layerOrder) || !Number.isInteger(targetPosition)) return;
  try {
    const payload = await labRequest(
      `/genomes/${genomeId}/weights?layer_order=${layerOrder}&target_position=${targetPosition}&limit=128&offset=${neuralLabState.weightOffset}`,
    );
    const weights = payload.weights ?? [];
    labWeights.replaceChildren();
    if (!weights.length) {
      labWeightBias.textContent = 'Bias do neurônio selecionado: sem dados';
      const empty = document.createElement('p');
      empty.className = 'lab-empty';
      empty.textContent = 'Este neurônio ainda não tem pesos consultáveis para o genoma selecionado.';
      labWeights.append(empty);
      labWeightPage.textContent = 'Sem pesos';
      labWeightPrevious.disabled = true;
      labWeightNext.disabled = true;
      return;
    }
    const first = weights[0];
    labWeightBias.textContent = first.target_bias !== null
      && first.target_bias !== undefined
      && Number.isFinite(Number(first.target_bias))
      ? `Bias do neurônio ${first.target_position}: ${Number(first.target_bias).toPrecision(7)}`
      : `Bias do neurônio ${first.target_position}: indisponível`;
    neuralLabState.weightTotal = Number(first.incoming_weight_count) || weights.length;
    const pageCount = Math.max(1, Math.ceil(neuralLabState.weightTotal / 128));
    const page = Math.floor(neuralLabState.weightOffset / 128) + 1;
    labWeightPage.textContent = `Página ${page}/${pageCount} · ${neuralLabState.weightTotal} pesos`;
    labWeightPrevious.disabled = neuralLabState.weightOffset <= 0;
    labWeightNext.disabled = neuralLabState.weightOffset + weights.length >= neuralLabState.weightTotal;
    const maxMagnitude = Math.max(0.000001, ...weights.map((item) => Math.abs(Number(item.weight) || 0)));
    for (const weight of weights) {
      const row = document.createElement('div');
      row.className = 'lab-weight-row';
      const label = document.createElement('span');
      label.textContent = `N${weight.source_position} → N${weight.target_position}`;
      const bar = document.createElement('span');
      bar.className = `lab-weight-bar${Number(weight.weight) < 0 ? ' negative' : ''}`;
      bar.style.setProperty('--weight-size', `${Math.max(1, Math.min(100, Math.abs(Number(weight.weight)) / maxMagnitude * 100))}%`);
      const value = document.createElement('code');
      value.textContent = Number(weight.weight).toPrecision(7);
      row.append(label, bar, value);
      labWeights.append(row);
    }
  } catch (error) {
    labWeights.textContent = `Não foi possível consultar os pesos: ${error.message}`;
  }
}

function updateTopologyEstimate() {
  try {
    const metrics = parseTopology(labNewTopology.value);
    labParameterCount.textContent = `${formatTopology(metrics.topology)} · ${metrics.weights.toLocaleString()} pesos · ${metrics.biases.toLocaleString()} biases · ${metrics.parameters.toLocaleString()} parâmetros treináveis`;
    labParameterCount.dataset.valid = 'true';
  } catch (error) {
    labParameterCount.textContent = error.message;
    labParameterCount.dataset.valid = 'false';
  }
}

async function submitLabArchitecture() {
  try {
    const topology = parseTopology(labNewTopology.value).topology;
    const name = labNewName.value.trim();
    if (!name) throw new Error('Informe um nome único para a arquitetura.');
    labCreateArchitecture.disabled = true;
    setLabStatus('Criando arquitetura por procedure SQL…', 'pending');
    await labRequest('/architectures', {
      method: 'POST',
      body: JSON.stringify({ architecture_name: name, topology, hidden_activation: labHiddenActivation.value }),
    });
    setLabStatus('Arquitetura criada; nenhum genoma foi sobrescrito.', 'ok');
    await loadLabArchitectures(name);
  } catch (error) {
    setLabStatus(`Arquitetura não criada: ${error.message}`, 'error');
  } finally {
    labCreateArchitecture.disabled = false;
  }
}

async function submitLabPopulation() {
  const architecture = neuralLabState.architectures.find(
    (item) => item.architecture_name === neuralLabState.populationTargetName,
  );
  if (!architecture) return;
  try {
    const populationSize = Number(labPopulationSize.value);
    const seed = Number(labPopulationSeed.value);
    labCreatePopulation.disabled = true;
    setLabStatus('Inicializando população vazia por procedure SQL…', 'pending');
    await labRequest(`/architectures/${encodeURIComponent(architecture.architecture_name)}/population`, {
      method: 'POST',
      body: JSON.stringify({ population_size: populationSize, seed }),
    });
    setLabStatus(`População inicializada com semente ${seed}; ela ainda não foi treinada. Dados existentes preservados.`, 'ok');
    await loadLabArchitectures(architecture.architecture_name);
  } catch (error) {
    setLabStatus(`População não criada: ${error.message}`, 'error');
    labCreatePopulation.disabled = false;
  }
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
  lastRequestAtByNpc: new Map(),
  lastResultLogAt: 0,
  metrics: createAiMetrics(),
  metricsTimer: null,
  pending: new Map(),
  reconnectTimer: null,
  requestSequence: 0,
  sessionArchitectureLocked: false,
  socket: null,
};

function updateAiMetricsDisplay(metrics = aiBridgeState.metrics) {
  aiDebugMetrics.textContent = formatAiMetrics(metrics);
}

function sendActionMetricsSnapshot(sessionId = state.sessionId, { force = false } = {}) {
  if (
    !sessionId
    || (!force && aiProvider.value !== 'backend')
    || aiBridgeState.socket?.readyState !== WebSocket.OPEN
  ) {
    return false;
  }

  aiBridgeState.socket.send(JSON.stringify({
    type: 'action_metrics',
    session_id: sessionId,
    metrics: snapshotAiMetrics(aiBridgeState.metrics),
  }));
  return true;
}

function startAiMetricsSync() {
  if (aiBridgeState.metricsTimer) {
    window.clearInterval(aiBridgeState.metricsTimer);
  }

  updateAiMetricsDisplay();
  sendActionMetricsSnapshot();
  aiBridgeState.metricsTimer = window.setInterval(() => {
    updateAiMetricsDisplay();
    sendActionMetricsSnapshot();
  }, 2000);
}

function stopAiMetricsSync() {
  if (aiBridgeState.metricsTimer) {
    window.clearInterval(aiBridgeState.metricsTimer);
    aiBridgeState.metricsTimer = null;
  }
}

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
    sendActionMetricsSnapshot();
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
        if (response.session_id === state.sessionId && response.action_metrics) {
          updateAiMetricsDisplay(response.action_metrics);
        }
        if (response.closed === true && typeof response.ack_token === 'string') {
          if (socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({
              type: 'session_end_ack_receipt',
              session_id: response.session_id,
              ack_token: response.ack_token,
            }));
          } else {
            appendLog('error', '[AI BRIDGE] conexão fechou antes da confirmação do ACK de treinamento.');
          }
        }
        return;
      }

      if (response.type === 'session_end_ack_receipt_ack') {
        if (response.confirmed === false) {
          appendLog('error', '[AI BRIDGE] MySQL não confirmou o recebimento do ACK de treinamento.');
        }
        return;
      }

      if (response.type === 'action_metrics_ack') {
        if (response.accepted === false) {
          appendLog('error', '[AI BRIDGE] backend rejeitou o resumo de ações da sessão.');
        }
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
        if (pendingRequest && pendingRequest.sessionId === state.sessionId) {
          recordInvalidSqlResponse(aiBridgeState.metrics);
        }
        aiBridgeState.decisions.delete(response.npc_id);
        appendLog('error', '[AI BRIDGE] invalid backend response; ORIGINAL_AI fallback active.');
        return;
      }

      recordSqlDecision(aiBridgeState.metrics, response.action);
      aiBridgeState.decisions.set(response.npc_id, {
        action,
        npcState: pendingRequest.npcState,
        receivedAt: Date.now(),
        requestStartedAtPerformance: pendingRequest.performanceStartedAt,
        runId: response.run_id,
        architectureName: response.architecture_name,
        mysqlInferenceMs: response.mysql_inference_ms,
        databaseRoundTripMs: response.database_round_trip_ms,
      });
      const websocketRttMs = performance.now() - pendingRequest.performanceStartedAt;
      neuralLabState.latestDecision = {
        runId: response.run_id,
        npcId: response.npc_id,
        architectureName: response.architecture_name || neuralLabState.selectedArchitectureName,
        action: response.action,
        confidence: response.confidence,
        mysqlInferenceMs: response.mysql_inference_ms,
        databaseRoundTripMs: response.database_round_trip_ms,
        websocketRttMs,
      };
      neuralLabState.latestEngineOutcome = 'Aguardando confirmação do engine';
      if (response.architecture_name && !neuralLabState.architectures.length) {
        neuralLabState.selectedArchitectureName = response.architecture_name;
      }
      renderLatestDecisionSummary();
      scheduleLabRunRefresh();
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
    aiBridgeState.lastRequestAtByNpc.clear();
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
  aiBridgeState.lastRequestAtByNpc.clear();
  setBackendStatus(status);
}

async function waitForAiRequestsToDrain(timeoutMs = 1700) {
  const deadline = Date.now() + timeoutMs;
  while (aiBridgeState.inflight.size > 0 && Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 25));
  }

  if (aiBridgeState.inflight.size > 0) {
    appendLog('info', `[AI BRIDGE] encerrando com ${aiBridgeState.inflight.size} decisão(ões) ainda sem resposta.`);
  }
}

async function finishAiSession() {
  const sessionId = state.sessionId;
  const socket = aiBridgeState.socket;
  let closed = false;

  stopAiMetricsSync();
  if (sessionId) {
    if (socket?.readyState === WebSocket.OPEN) {
      await waitForAiRequestsToDrain();
    }
    if (socket?.readyState === WebSocket.OPEN) {
      closed = await new Promise((resolve) => {
        let awaitingReceipt = false;
        const timeout = window.setTimeout(() => finish(false), 4500);
        const onMessage = (event) => {
          try {
            const response = JSON.parse(event.data);
            if (response.type === 'session_end_ack' && response.session_id === sessionId) {
              if (response.closed !== true) {
                finish(false);
              } else if (typeof response.ack_token === 'string') {
                awaitingReceipt = true;
              } else {
                finish(true);
              }
            } else if (
              response.type === 'session_end_ack_receipt_ack'
              && response.session_id === sessionId
              && awaitingReceipt
            ) {
              finish(response.confirmed === true);
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
        sendActionMetricsSnapshot(sessionId, { force: true });
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
  aiBridgeState.lastRequestAtByNpc.clear();
  aiBridgeState.sessionArchitectureLocked = false;
  labArchitectureSelect.disabled = !neuralLabState.architectures.some(isPlayableArchitecture);
  updateGameGenomePinControl();
  updateLabRecommendations();
  return closed;
}

function requestBackendDecision(npcState) {
  const now = Date.now();
  const npcId = String(npcState.npc_id);
  const lastRequestAt = aiBridgeState.lastRequestAtByNpc.get(npcId) ?? 0;
  const hasInflightRequest = [...aiBridgeState.inflight.values()].some(
    (request) => String(request.npcState.npc_id) === npcId,
  );

  if (
    now - lastRequestAt < 250
    || hasInflightRequest
    || aiBridgeState.socket?.readyState !== WebSocket.OPEN
  ) {
    return;
  }

  const requestId = `${npcState.npc_id}-${now}-${++aiBridgeState.requestSequence}`;
  aiBridgeState.lastRequestAtByNpc.set(npcId, now);
  aiBridgeState.sessionArchitectureLocked = true;
  labArchitectureSelect.disabled = true;
  updateGameGenomePinControl();
  updateLabRecommendations();
  const performanceStartedAt = performance.now();
  aiBridgeState.inflight.set(requestId, {
    npcState,
    sentAt: now,
    performanceStartedAt,
    sessionId: state.sessionId,
  });
  const pinnedGenomeId = neuralLabState.selectedGameGenomeArchitecture === neuralLabState.selectedArchitectureName
    ? neuralLabState.selectedGameGenomeId
    : null;
  aiBridgeState.socket.send(JSON.stringify({
    type: 'npc_state',
    request_id: requestId,
    session_id: state.sessionId,
    architecture_name: neuralLabState.selectedArchitectureName,
    ...(pinnedGenomeId ? { genome_id: pinnedGenomeId } : {}),
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
      recordOpportunity(aiBridgeState.metrics);
      connectAiBackend();
      requestBackendDecision(npcState);

      const decision = aiBridgeState.decisions.get(npcState.npc_id);
      if (decision && Date.now() - decision.receivedAt <= 1000) {
        const actionName = AI_ACTION_NAME[decision.action];
        if (recordEngineOffer(aiBridgeState.metrics, actionName)) {
          aiBridgeState.pending.set(npcState.npc_id, {
            action: decision.action,
            actionName,
            npcState,
            source: 'backend',
            requestStartedAtPerformance: decision.requestStartedAtPerformance,
            offeredAtPerformance: performance.now(),
          });
          return decision.action;
        }
      }

      const now = Date.now();
      const fallbackReason = aiBridgeState.socket?.readyState === WebSocket.OPEN
        ? 'waiting_for_mysql'
        : 'backend_offline';
      recordFallback(aiBridgeState.metrics, fallbackReason);
      neuralLabState.latestEngineOutcome = 'Ação neural ausente; controle mantido pela IA original';
      if (neuralLabPanel.open) {
        labLiveAction.textContent = `ORIGINAL_AI fallback · ${fallbackReason}`;
        labLiveEngineResult.textContent = neuralLabState.latestEngineOutcome;
      }

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
    aiBridgeState.pending.set(npcState.npc_id, {
      action,
      actionName: AI_ACTION_NAME[action],
      npcState,
      source: 'local',
    });
    return action;
  },

  receiveResult(result) {
    const pending = aiBridgeState.pending.get(result.npc_id);

    if (!pending) {
      return;
    }

    if (pending.source === 'backend') {
      recordEngineResult(aiBridgeState.metrics, pending.actionName, result.applied);
      const endToEndMs = performance.now() - pending.requestStartedAtPerformance;
      neuralLabState.latestEngineOutcome = result.applied
        ? `${pending.actionName} aceita e aplicada pelo engine · ${endToEndMs.toFixed(2)} ms desde a consulta`
        : `${pending.actionName} rejeitada pelo engine · ${endToEndMs.toFixed(2)} ms; fallback ORIGINAL_AI`;
      if (neuralLabPanel.open) labLiveEngineResult.textContent = neuralLabState.latestEngineOutcome;
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
  aiProvider.disabled = false;

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
  stopAiMetricsSync();
  aiBridgeState.metrics = createAiMetrics();
  aiBridgeState.pending.clear();
  aiBridgeState.lastRequestAtByNpc.clear();
  updateAiMetricsDisplay();
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
    startAiMetricsSync();
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
neuralLabPanel.addEventListener('toggle', () => {
  if (!neuralLabPanel.open) return;
  renderLatestDecisionSummary();
  labArchitectureSelect.disabled = aiBridgeState.sessionArchitectureLocked;
  if (!neuralLabState.architectures.length) {
    void loadLabArchitectures();
  } else {
    void loadLabArchitectureDetails();
    scheduleLabRunRefresh(0);
  }
});
labArchitectureSelect.addEventListener('change', () => {
  if (aiBridgeState.sessionArchitectureLocked) {
    labArchitectureSelect.value = neuralLabState.selectedArchitectureName ?? '';
    setLabStatus('A arquitetura desta sessão já foi fixada; selecione outra após encerrá-la.', 'error');
    return;
  }
  const selected = neuralLabState.architectures.find(
    (architecture) => architecture.architecture_name === labArchitectureSelect.value,
  );
  if (!selected) return;
  neuralLabState.selectedArchitectureId = selected.architecture_id;
  neuralLabState.selectedArchitectureName = selected.architecture_name;
  neuralLabState.selectedGeneration = null;
  neuralLabState.activationOffset = 0;
  neuralLabState.weightOffset = 0;
  localStorage.setItem(NEURAL_LAB_STORAGE_KEY, selected.architecture_name);
  void loadLabArchitectureDetails();
});
labApplyRecommended.addEventListener('click', () => {
  void applyRecommendedArchitecture(neuralLabState.recommendedCandidate);
});
labApplyAlternative.addEventListener('click', () => {
  void applyRecommendedArchitecture(neuralLabState.recommendedAlternative);
});
labPinGenome.addEventListener('click', () => {
  if (aiBridgeState.sessionArchitectureLocked) {
    setLabStatus('A seleção de genoma está travada até o encerramento desta sessão.', 'error');
    return;
  }
  const architecture = selectedLabArchitecture();
  const genomeId = Number(neuralLabState.selectedGenomeId);
  if (!architecture || !Number.isInteger(genomeId) || genomeId < 1) return;
  const samePinnedGenome = neuralLabState.selectedGameGenomeArchitecture === architecture.architecture_name
    && String(neuralLabState.selectedGameGenomeId) === String(genomeId);
  if (samePinnedGenome) {
    neuralLabState.selectedGameGenomeId = null;
    neuralLabState.selectedGameGenomeArchitecture = null;
    localStorage.removeItem(NEURAL_LAB_GENOME_STORAGE_KEY);
    setLabStatus('Genoma fixado removido; o SQL balanceará o roster na próxima sessão.', 'ok');
  } else {
    neuralLabState.selectedGameGenomeId = genomeId;
    neuralLabState.selectedGameGenomeArchitecture = architecture.architecture_name;
    localStorage.setItem(NEURAL_LAB_GENOME_STORAGE_KEY, JSON.stringify({
      architectureName: architecture.architecture_name,
      genomeId,
    }));
    setLabStatus(`Genoma #${genomeId} selecionado para a próxima sessão; a atual não será alterada.`, 'ok');
  }
  updateGameGenomePinControl();
});
labPopulationTarget.addEventListener('change', () => {
  neuralLabState.populationTargetName = labPopulationTarget.value || null;
  void loadPopulationTargetDetails();
});
labGenerationSelect.addEventListener('change', () => {
  neuralLabState.selectedGeneration = Number(labGenerationSelect.value);
  neuralLabState.weightOffset = 0;
  void loadLabGenomes().then(loadLabWeights);
});
labGenomeSelect.addEventListener('change', () => {
  neuralLabState.selectedGenomeId = Number(labGenomeSelect.value) || null;
  neuralLabState.weightOffset = 0;
  labWeightLayer.disabled = !neuralLabState.selectedGenomeId || neuralLabState.layers.length < 2;
  void loadLabWeights();
});
labInspectionLayer.addEventListener('change', () => {
  neuralLabState.activationOffset = 0;
  scheduleLabRunRefresh(0);
});
labActivationPrevious.addEventListener('click', () => {
  neuralLabState.activationOffset = Math.max(0, neuralLabState.activationOffset - 128);
  void refreshLabRun();
});
labActivationNext.addEventListener('click', () => {
  if (neuralLabState.activationOffset + 128 < neuralLabState.activationTotal) {
    neuralLabState.activationOffset += 128;
    void refreshLabRun();
  }
});
labWeightLayer.addEventListener('change', () => {
  neuralLabState.weightOffset = 0;
  void loadLabWeights();
});
labWeightTarget.addEventListener('change', () => {
  neuralLabState.weightOffset = 0;
  void loadLabWeights();
});
labLoadWeights.addEventListener('click', () => {
  neuralLabState.weightOffset = 0;
  void loadLabWeights();
});
labUseLiveGenome.addEventListener('click', async () => {
  const liveGenome = neuralLabState.liveGenome;
  if (!liveGenome) return;
  if (String(liveGenome.architectureId) !== String(neuralLabState.selectedArchitectureId)) {
    setLabStatus('O genoma vivo pertence a outra arquitetura; a sessão atual preserva sua seleção.', 'error');
    return;
  }
  neuralLabState.selectedGeneration = Number(liveGenome.generation);
  const generationAvailable = [...labGenerationSelect.options]
    .some((option) => Number(option.value) === neuralLabState.selectedGeneration);
  if (!generationAvailable) {
    addLabOption(labGenerationSelect, neuralLabState.selectedGeneration, `Geração ${neuralLabState.selectedGeneration}`);
  }
  labGenerationSelect.value = String(neuralLabState.selectedGeneration);
  await loadLabGenomes();
  const liveOption = neuralLabState.genomes.find(
    (genome) => String(genome.genome_id) === String(liveGenome.genomeId),
  );
  if (liveOption) {
    neuralLabState.selectedGenomeId = liveOption.genome_id;
    labGenomeSelect.value = String(liveOption.genome_id);
    neuralLabState.weightOffset = 0;
    await loadLabWeights();
    setLabStatus(`Inspecionando o genoma #${liveGenome.genomeId} usado pelo NPC.`, 'ok');
  } else {
    setLabStatus('O genoma vivo não está na página atual de inspeção.', 'error');
  }
});
labWeightPrevious.addEventListener('click', () => {
  neuralLabState.weightOffset = Math.max(0, neuralLabState.weightOffset - 128);
  void loadLabWeights();
});
labWeightNext.addEventListener('click', () => {
  if (neuralLabState.weightOffset + 128 < neuralLabState.weightTotal) {
    neuralLabState.weightOffset += 128;
    void loadLabWeights();
  }
});
labNewTopology.addEventListener('input', updateTopologyEstimate);
labCreateArchitecture.addEventListener('click', () => void submitLabArchitecture());
labCreatePopulation.addEventListener('click', () => void submitLabPopulation());
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
  sendActionMetricsSnapshot(state.sessionId, { force: true });
  aiBridgeState.socket.send(JSON.stringify({
    type: 'session_end',
    session_id: state.sessionId,
  }));
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && neuralLabPanel.open) scheduleLabRunRefresh(0);
});

canvas.addEventListener('click', () => {
  if (state.running) {
    canvas.focus();
  }
});

setStatus('Ready');
updateTopologyEstimate();
updateButtons();
syncSelectionSummary();
renderPersistedSelection();
syncAiMode({ log: false });
appendLog('info', 'Browser shell ready. Click Play to boot Freedoom.');
