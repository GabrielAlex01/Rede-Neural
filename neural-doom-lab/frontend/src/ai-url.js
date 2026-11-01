export function resolveAiWebSocketUrl(location, override = '') {
  if (override) return override;

  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${location.hostname}:8000/ws/ai`;
}
