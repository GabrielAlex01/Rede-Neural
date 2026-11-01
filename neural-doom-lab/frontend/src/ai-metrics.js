export const AI_ACTION_NAMES = Object.freeze(['IDLE', 'CHASE', 'ATTACK', 'FLEE']);

const FALLBACK_REASONS = Object.freeze(['backend_offline', 'waiting_for_mysql']);

export function createAiMetrics() {
  return {
    opportunities: 0,
    sql_decisions: 0,
    invalid_sql_responses: 0,
    sent_to_engine: 0,
    applied: 0,
    rejected: 0,
    fallback: 0,
    actions: Object.fromEntries(AI_ACTION_NAMES.map((action) => [action, {
      selected: 0,
      sent_to_engine: 0,
      applied: 0,
      rejected: 0,
    }])),
    fallback_reasons: Object.fromEntries(FALLBACK_REASONS.map((reason) => [reason, 0])),
  };
}

export function recordOpportunity(metrics) {
  metrics.opportunities += 1;
}

export function recordSqlDecision(metrics, action) {
  const actionMetrics = metrics.actions[action];
  if (!actionMetrics) {
    metrics.invalid_sql_responses += 1;
    return false;
  }

  metrics.sql_decisions += 1;
  actionMetrics.selected += 1;
  return true;
}

export function recordInvalidSqlResponse(metrics) {
  metrics.invalid_sql_responses += 1;
}

export function recordEngineOffer(metrics, action) {
  const actionMetrics = metrics.actions[action];
  if (!actionMetrics) {
    return false;
  }

  metrics.sent_to_engine += 1;
  actionMetrics.sent_to_engine += 1;
  return true;
}

export function recordEngineResult(metrics, action, applied) {
  const actionMetrics = metrics.actions[action];
  if (!actionMetrics || typeof applied !== 'boolean') {
    return false;
  }

  const outcome = applied ? 'applied' : 'rejected';
  metrics[outcome] += 1;
  actionMetrics[outcome] += 1;
  return true;
}

export function recordFallback(metrics, reason) {
  if (!Object.hasOwn(metrics.fallback_reasons, reason)) {
    reason = 'waiting_for_mysql';
  }

  metrics.fallback += 1;
  metrics.fallback_reasons[reason] += 1;
}

export function snapshotAiMetrics(metrics) {
  return {
    opportunities: metrics.opportunities,
    sql_decisions: metrics.sql_decisions,
    invalid_sql_responses: metrics.invalid_sql_responses,
    sent_to_engine: metrics.sent_to_engine,
    applied: metrics.applied,
    rejected: metrics.rejected,
    fallback: metrics.fallback,
    actions: Object.fromEntries(AI_ACTION_NAMES.map((action) => [action, { ...metrics.actions[action] }])),
    fallback_reasons: { ...metrics.fallback_reasons },
  };
}

export function formatAiMetrics(metrics) {
  const unresolved = Math.max(0, metrics.sent_to_engine - metrics.applied - metrics.rejected);
  const applicationRate = metrics.sent_to_engine
    ? Math.round((metrics.applied / metrics.sent_to_engine) * 100)
    : 0;
  const perAction = AI_ACTION_NAMES.map((action) => {
    const counts = metrics.actions[action];
    return `${action}: SQL ${counts.selected}, engine ${counts.sent_to_engine}, aplic. ${counts.applied}, rejeit. ${counts.rejected}`;
  }).join('\n');

  return `SQL ${metrics.sql_decisions} (inválidas ${metrics.invalid_sql_responses}) · engine ${metrics.sent_to_engine} · aplicadas ${metrics.applied} (${applicationRate}%) · rejeitadas ${metrics.rejected} · ORIGINAL_AI ${metrics.fallback} · sem retorno ${unresolved}\n${perAction}`;
}
