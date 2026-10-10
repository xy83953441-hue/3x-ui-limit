// Validate serialized fields so edits in the advanced JSON tab are checked too.
export function validateInbound(port, stream = {}, settings = {}) {
  if (!Number.isInteger(Number(port)) || Number(port) < 1 || Number(port) > 65535) {
    return '端口必须是 1—65535 的整数。';
  }
  if (stream.security === 'reality') {
    const r = stream.realitySettings || {};
    if (!String(r.target ?? r.dest ?? '').trim()) return 'REALITY 需要填写目标地址（Target）。';
    if (!r.privateKey || !/^[A-Za-z0-9_-]{43}$/.test(r.privateKey)) {
      return '请为 REALITY 生成有效的 X25519 密钥。';
    }
    if (!Array.isArray(r.serverNames) || !r.serverNames.length || r.serverNames.some(s => typeof s !== 'string' || !s.trim())) {
      return '请填写 REALITY 服务名称（SNI）。';
    }
    if (!Array.isArray(r.shortIds) || !r.shortIds.length || r.shortIds.some(id => typeof id !== 'string' || !/^(?:[a-fA-F0-9]{2}){0,8}$/.test(id))) {
      return 'Short ID 必须为不超过 16 位的偶数位十六进制字符；也可保留空字符串。';
    }
  }
  if (settings.clients?.some(c => c.flow === 'xtls-rprx-vision') &&
      (!['tcp', 'raw', undefined].includes(stream.network) || !['tls', 'reality'].includes(stream.security))) {
    return 'Vision 流控需要 TCP（RAW）传输，并启用 TLS 或 REALITY。';
  }
  return '';
}
