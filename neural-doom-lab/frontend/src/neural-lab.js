export function calculateTopology(topology) {
  if (!Array.isArray(topology) || topology.length < 3 || topology.length > 8) {
    throw new TypeError('A topologia precisa ter de 3 a 8 camadas.');
  }
  if (topology.some((width) => !Number.isInteger(width) || width < 1 || width > 512)) {
    throw new TypeError('Cada camada precisa ter entre 1 e 512 neurônios.');
  }
  if (topology[0] !== 4 || topology.at(-1) !== 4) {
    throw new TypeError('A rede precisa preservar as quatro entradas e quatro saídas reais.');
  }

  let weights = 0;
  let biases = 0;
  for (let index = 1; index < topology.length; index += 1) {
    weights += topology[index - 1] * topology[index];
    biases += topology[index];
  }
  if (weights + biases > 120_000) {
    throw new TypeError('A arquitetura ultrapassa o limite de 120000 parâmetros treináveis.');
  }
  return {
    topology: [...topology],
    weights,
    biases,
    parameters: weights + biases,
    neurons: topology.reduce((sum, width) => sum + width, 0),
  };
}

export function parseTopology(value) {
  const pieces = String(value).split(/[\s,;→>-]+/).filter(Boolean);
  if (pieces.length < 3 || pieces.some((piece) => !/^\d+$/.test(piece))) {
    throw new TypeError('Informe as larguras separadas por vírgula, por exemplo 4,64,4.');
  }
  return calculateTopology(pieces.map(Number));
}

export function formatTopology(topology) {
  return Array.isArray(topology) ? topology.join(' → ') : String(topology ?? '—');
}
