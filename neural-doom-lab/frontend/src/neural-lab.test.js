import test from 'node:test';
import assert from 'node:assert/strict';

import {
  calculateTopology,
  findPlayableArchitecture,
  formatTopology,
  isPlayableArchitecture,
  parseTopology,
} from './neural-lab.js';

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

test('only offers architectures that the active SQL catalog marks playable', () => {
  const catalog = [
    { architecture_name: 'closed_v2', topology: '4 -> 32 -> 4', input_count: 4, output_count: 4, genome_count: 16, playable_generation: null, playable: 0 },
    { architecture_name: 'usable_h32', topology: '4 -> 32 -> 4', input_count: 4, output_count: 4, genome_count: 8, playable_generation: 1, playable: 1 },
    { architecture_name: 'empty_h6', topology: '4 -> 6 -> 4', input_count: 4, output_count: 4, genome_count: 0, playable_generation: null, playable: 0 },
  ];

  assert.equal(isPlayableArchitecture(catalog[0]), false);
  assert.equal(isPlayableArchitecture(catalog[1]), true);
  assert.equal(isPlayableArchitecture(catalog[2]), false);
  assert.equal(findPlayableArchitecture(catalog, [4, 32, 4]), catalog[1]);
  assert.equal(findPlayableArchitecture(catalog, [4, 6, 4]), null);
});
