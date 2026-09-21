import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const maxWire = 12 * 1024 * 1024;
const maxCombined = 8 * 1024 * 1024 + 28;
const tokenPattern = /^[A-Za-z0-9+/]{43}=$/;
export const binaryType = 'application/vnd.phonesnap.encrypted.v1';
export const maxBinary = 8 + 512 + maxCombined;

function validMetadata(value) {
  return value && Object.keys(value).sort().join(',') === 'channel,expires,transfer,version' &&
    value.version === 1 && typeof value.channel === 'string' && uuid.test(value.channel) &&
    typeof value.transfer === 'string' && uuid.test(value.transfer) &&
    Number.isSafeInteger(value.expires) && value.expires > 0;
}

export function encodeBinary(envelope) {
  const { version, channel, transfer, expires, ciphertext } = envelope;
  const metadata = { version, channel, transfer, expires };
  if (!validMetadata(metadata) || typeof ciphertext !== 'string' || ciphertext.length > maxWire) throw 400;
  const combined = Buffer.from(ciphertext, 'base64');
  if (combined.length <= 28 || combined.length > maxCombined || combined.toString('base64') !== ciphertext) throw 400;
  const header = Buffer.from(JSON.stringify(metadata));
  if (header.length > 512) throw 400;
  const prefix = Buffer.alloc(8);
  prefix.write('PSB1'); prefix.writeUInt32BE(header.length, 4);
  return Buffer.concat([prefix, header, combined]);
}

export function decodeBinary(frame) {
  if (frame.length > maxBinary) throw 413;
  if (frame.length < 8 || !frame.subarray(0, 4).equals(Buffer.from('PSB1'))) throw 400;
  const size = frame.readUInt32BE(4);
  if (!size || size > 512 || frame.length <= 8 + size + 28 || frame.length - 8 - size > maxCombined) throw 400;
  let metadata;
  try { metadata = JSON.parse(frame.subarray(8, 8 + size).toString('utf8')); } catch { throw 400; }
  if (!validMetadata(metadata)) throw 400;
  return { ...metadata, ciphertext: frame.subarray(8 + size).toString('base64') };
}

function equal(value, expected) {
  const supplied = Buffer.from(value ?? '');
  const target = Buffer.from(`Bearer ${expected}`);
  return supplied.length === target.length && timingSafeEqual(supplied, target);
}

function reply(response, status, body, contentType = 'application/json') {
  if (response.writableEnded || response.destroyed) return;
  response.writeHead(status, { 'Content-Type': contentType, 'Cache-Control': 'no-store', 'Connection': 'close' });
  response.end(body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body));
}

async function readJSON(request, limit, onRead, allowBinary = false) {
  const binary = allowBinary && request.headers['content-type'] === binaryType;
  if ((!binary && request.headers['content-type'] !== 'application/json') || request.headers['content-encoding']) throw 415;
  if (binary) limit = maxBinary;
  if (Number(request.headers['content-length']) > limit) throw 413;
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw 413;
    chunks.push(chunk);
  }
  onRead?.(size);
  if (binary) return decodeBinary(Buffer.concat(chunks));
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw 400; }
}

function validEnvelope(value, channel, transfer) {
  if (!value || Object.keys(value).sort().join(',') !== 'channel,ciphertext,expires,transfer,version') return false;
  const now = Math.floor(Date.now() / 1000);
  if (value.version !== 1 || value.channel !== channel || value.transfer !== transfer ||
      !Number.isSafeInteger(value.expires) || value.expires <= now || value.expires > now + 95 ||
      typeof value.ciphertext !== 'string' || value.ciphertext.length > maxWire) return false;
  const bytes = Buffer.from(value.ciphertext, 'base64');
  return bytes.length > 28 && bytes.length <= maxCombined && bytes.toString('base64') === value.ciphertext;
}

function forward(response, pending) {
  const binary = response.binaryRelay === true;
  const body = binary ? encodeBinary(pending.envelope) : Buffer.from(JSON.stringify(pending.envelope));
  pending.log('forward_enqueued', { wire: binary ? 'binary' : 'json', bytes: body.length });
  response.on('finish', () => pending.log('forward_finished'));
  response.on('close', () => {
    if (!response.writableFinished) pending.log('forward_disconnected');
  });
  reply(response, 200, body, binary ? binaryType : 'application/json');
}

export function createRelay(config, { pollMS = 20000, uploadMS = 60000, diagnostic = event => console.log(JSON.stringify(event)) } = {}) {
  if (!config || Object.keys(config).join(',') !== 'channels' || !Array.isArray(config.channels) ||
      config.channels.length < 1 || config.channels.length > 8) throw new Error('Invalid relay config');
  const channels = new Map();
  const tokens = new Set();
  for (const item of config.channels) {
    if (Object.keys(item).sort().join(',') !== 'channel,receiveToken,uploadToken' || !uuid.test(item.channel) ||
        !tokenPattern.test(item.uploadToken) || !tokenPattern.test(item.receiveToken) ||
        item.uploadToken === item.receiveToken || channels.has(item.channel) ||
        tokens.has(item.uploadToken) || tokens.has(item.receiveToken)) throw new Error('Invalid relay config');
    tokens.add(item.uploadToken); tokens.add(item.receiveToken);
    channels.set(item.channel, { ...item, onlineUntil: 0, poll: null, pending: null, reading: false });
  }
  let readers = 0;
  const server = http.createServer(async (request, response) => {
    const began = performance.now();
    const timestamp = new Date().toISOString();
    try {
      if (request.method === 'GET' && request.url === '/healthz') return reply(response, 200, { relay: 'e2ee-v1' });
      const match = /^\/v1\/([^/]+)\/(next|transfers\/([^/]+)(\/receipt)?)$/.exec(request.url ?? '');
      if (!match || !uuid.test(match[1])) return reply(response, 404);
      const state = channels.get(match[1]);
      const isPoll = match[2] === 'next';
      const isReceipt = Boolean(match[4]);
      if (!isPoll && !uuid.test(match[3])) return reply(response, 404);
      if ((isPoll && request.method !== 'GET') || (!isPoll && request.method !== 'POST')) return reply(response, 405);
      if (!state || !equal(request.headers.authorization, isPoll || isReceipt ? state.receiveToken : state.uploadToken)) {
        return reply(response, 401);
      }
      const log = (event, details = {}) => {
        try {
          diagnostic({ diagnostic: 'phonesnap-relay-v1', transfer: match[3], event, started_utc: timestamp,
            elapsed_ms: Math.max(0, performance.now() - began), ...details });
        } catch {}
      };
      if (isPoll) {
        response.binaryRelay = (request.headers.accept ?? '').split(',').some(value => value.trim() === binaryType);
        state.onlineUntil = Date.now() + 30000;
        if (state.poll) return reply(response, 409);
        if (state.pending) {
          return forward(response, state.pending);
        }
        const timer = setTimeout(() => reply(response, 204), pollMS);
        state.poll = response;
        response.on('close', () => { clearTimeout(timer); if (state.poll === response) state.poll = null; });
        return;
      }
      log(isReceipt ? 'receipt_headers' : 'upload_headers');
      response.on('finish', () => log(isReceipt ? 'receipt_finished' : 'upload_finished', { status: response.statusCode }));
      response.on('close', () => {
        if (!response.writableFinished) log(isReceipt ? 'receipt_disconnected' : 'upload_disconnected');
      });
      if (!isReceipt && (state.pending || state.reading)) return reply(response, 409);
      if (!isReceipt && state.onlineUntil <= Date.now()) return reply(response, 503);
      if (readers >= 4) return reply(response, 429);
      readers += 1;
      if (!isReceipt) state.reading = true;
      let body;
      try {
        body = await readJSON(request, isReceipt ? 8192 : maxWire,
          bytes => log(isReceipt ? 'receipt_body_read' : 'upload_body_read', { bytes }), !isReceipt);
      }
      finally { readers -= 1; if (!isReceipt) state.reading = false; }
      if (isReceipt) {
        if (!body || Object.keys(body).join(',') !== 'receipt' || typeof body.receipt !== 'string' ||
            !body.receipt.length || body.receipt.length > 4096) return reply(response, 400);
        const pending = state.pending;
        if (!pending || pending.envelope.transfer !== match[3]) return reply(response, 404);
        pending.log('receipt_received');
        state.pending = null;
        clearTimeout(pending.timer);
        reply(pending.response, 200, body);
        return reply(response, 200, { accepted: true });
      }
      if (!validEnvelope(body, match[1], match[3])) return reply(response, 400);
      if (state.onlineUntil <= Date.now()) return reply(response, 503);
      const pending = { envelope: body, response, timer: null, log };
      pending.timer = setTimeout(() => {
        if (state.pending === pending) state.pending = null;
        reply(response, 504);
      }, Math.min(uploadMS, body.expires * 1000 - Date.now()));
      state.pending = pending;
      response.on('close', () => {
        clearTimeout(pending.timer);
        if (state.pending === pending) state.pending = null;
      });
      if (state.poll) {
        const poll = state.poll;
        state.poll = null;
        forward(poll, pending);
      }
    } catch (error) { reply(response, Number.isInteger(error) ? error : 400); }
  });
  server.maxConnections = 32;
  server.headersTimeout = 10000;
  server.requestTimeout = 70000;
  server.setTimeout(75000, socket => socket.destroy());
  server.on('close', () => {
    for (const state of channels.values()) if (state.pending) clearTimeout(state.pending.timer);
  });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const config = JSON.parse(readFileSync(process.env.PHONESNAP_RELAY_CONFIG ?? '/config/channels.json', 'utf8'));
    const port = Number(process.env.PORT ?? 8787);
    const host = process.env.PHONESNAP_RELAY_HOST ?? '127.0.0.1';
    createRelay(config).listen(port, host, () => console.log('PHONESNAP_E2EE_RELAY_READY'));
  } catch { console.error('PHONESNAP_RELAY_CONFIG_INVALID'); process.exitCode = 1; }
}
