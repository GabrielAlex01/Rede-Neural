import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveAiWebSocketUrl } from './ai-url.js';

test('uses the local host for the default browser URL', () => {
  assert.equal(
    resolveAiWebSocketUrl({ protocol: 'http:', hostname: 'localhost' }),
    'ws://localhost:8000/ws/ai',
  );
});

test('targets the notebook host when opened from another computer', () => {
  assert.equal(
    resolveAiWebSocketUrl({ protocol: 'http:', hostname: '192.168.1.42' }),
    'ws://192.168.1.42:8000/ws/ai',
  );
});

test('uses secure WebSocket when the page uses HTTPS', () => {
  assert.equal(
    resolveAiWebSocketUrl({ protocol: 'https:', hostname: 'doom.example.test' }),
    'wss://doom.example.test:8000/ws/ai',
  );
});

test('respects an explicit WebSocket URL override', () => {
  assert.equal(
    resolveAiWebSocketUrl(
      { protocol: 'http:', hostname: 'localhost' },
      'ws://127.0.0.1:9000/ws/ai',
    ),
    'ws://127.0.0.1:9000/ws/ai',
  );
});
