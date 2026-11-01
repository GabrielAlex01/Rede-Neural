import assert from 'node:assert/strict';
import test from 'node:test';

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

test('tracks SQL selection separately from delivery and engine outcomes for every action', () => {
  const metrics = createAiMetrics();

  for (const action of ['IDLE', 'CHASE', 'ATTACK', 'FLEE']) {
    recordOpportunity(metrics);
    assert.equal(recordSqlDecision(metrics, action), true);
    assert.equal(recordEngineOffer(metrics, action), true);
    assert.equal(recordEngineResult(metrics, action, action !== 'ATTACK'), true);
  }
  recordOpportunity(metrics);
  recordFallback(metrics, 'backend_offline');
  recordInvalidSqlResponse(metrics);

  const snapshot = snapshotAiMetrics(metrics);
  assert.equal(snapshot.sql_decisions, 4);
  assert.equal(snapshot.sent_to_engine, 4);
  assert.equal(snapshot.applied, 3);
  assert.equal(snapshot.rejected, 1);
  assert.equal(snapshot.fallback, 1);
  assert.equal(snapshot.actions.ATTACK.selected, 1);
  assert.equal(snapshot.actions.ATTACK.rejected, 1);
  assert.equal(snapshot.fallback_reasons.backend_offline, 1);
  assert.match(formatAiMetrics(snapshot), /ATTACK: SQL 1, engine 1, aplic\. 0, rejeit\. 1/);
});

test('does not count invalid actions as engine offers or results', () => {
  const metrics = createAiMetrics();

  assert.equal(recordSqlDecision(metrics, 'INVALID'), false);
  assert.equal(recordEngineOffer(metrics, 'INVALID'), false);
  assert.equal(recordEngineResult(metrics, 'INVALID', true), false);
  assert.equal(metrics.sql_decisions, 0);
  assert.equal(metrics.sent_to_engine, 0);
  assert.equal(metrics.invalid_sql_responses, 1);
});
