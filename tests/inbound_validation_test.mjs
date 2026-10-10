import assert from 'node:assert/strict';
import { validateInbound } from '../frontend/src/utils/validateInbound.js';
const stream = { security: 'reality', network: 'tcp', realitySettings: {
  target: 'example.com:443', privateKey: 'A'.repeat(43), serverNames: ['example.com'], shortIds: ['abcd', ''],
} };
assert.equal(validateInbound(30455, stream), '');
assert.ok(validateInbound(70000, stream));
assert.ok(validateInbound(0, stream));
assert.ok(validateInbound(123.5, stream));
assert.ok(validateInbound(443, { ...stream, realitySettings: {} }));
assert.ok(validateInbound(443, { ...stream, realitySettings: { ...stream.realitySettings, shortIds: ['abc'] } }));
assert.ok(validateInbound(443, { ...stream, network: 'ws' }, { clients: [{ flow: 'xtls-rprx-vision' }] }));
assert.equal(validateInbound(443, stream, { clients: [{ flow: 'xtls-rprx-vision' }] }), '');
assert.equal(validateInbound(41601, { network: 'tcp', security: 'none' }), '');
console.log('Inbound validation passed');
