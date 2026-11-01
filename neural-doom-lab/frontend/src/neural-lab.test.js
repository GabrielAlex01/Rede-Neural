import test from 'node:test';
import assert from 'node:assert/strict';

import { calculateTopology, formatTopology, parseTopology } from './neural-lab.js';

test('counts trainable weights and biases for a 4-64-4 network', () => {
  assert.deepEqual(calculateTopology([4, 64, 4]), {
    topology: [4, 64, 4],
    weights: 512,
    biases: 68,
    parameters: 580,
    neurons: 72,
  });
});

test('parses user topology text and renders a concise layer summary', () => {
  assert.equal(formatTopology(parseTopology('4, 64, 32, 64, 4').topology), '4 → 64 → 32 → 64 → 4');
});

test('rejects artificial input/output widths and unsupported parameter sizes', () => {
  assert.throws(() => calculateTopology([5, 8, 4]), /quatro entradas/);
  assert.throws(() => calculateTopology([4, 512, 512, 4]), /120000/);
  assert.throws(() => calculateTopology([4, 0, 4]), /entre 1 e 512/);
});
