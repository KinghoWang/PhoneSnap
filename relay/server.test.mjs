import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import http from 'node:http';
import { createRelay, encodeBinary, decodeBinary, binaryType, maxBinary } from './server.mjs';

const channel = randomUUID();
const uploadToken = randomBytes(32).toString('base64');
const receiveToken = randomBytes(32).toString('base64');

async function fixture(run, events = []) {
  const server = createRelay({ channels: [{ channel, uploadToken, receiveToken }] }, { pollMS: 80, uploadMS: 300, diagnostic: event => events.push(event) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}/v1/${channel}`;
  const request = (path, token, body, headers = {}) => fetch(base + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...headers },
    body: body === undefined ? undefined : Buffer.isBuffer(body) ? body : JSON.stringify(body),
  });
  const oversizedHeaders = path => new Promise((resolve, reject) => {
    const oversized = http.request(base + path, {
      method: 'POST', headers: { Authorization: `Bearer ${uploadToken}`, 'Content-Type': 'application/json',
        'Content-Length': 12 * 1024 * 1024 + 1 }
    }, response => { response.resume(); response.on('end', () => resolve(response.statusCode)); });
    oversized.on('error', reject);
    oversized.setTimeout(2000, () => oversized.destroy(new Error('oversize rejection timeout')));
    oversized.end();
  });
  try { await run(request, oversizedHeaders); } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}

function envelope() {
  return { version: 1, channel, transfer: randomUUID(), expires: Math.floor(Date.now() / 1000) + 90,
    ciphertext: randomBytes(80).toString('base64') };
}

test('binary frame is bounded and preserves the canonical envelope', () => {
  const image = envelope();
  const wire = encodeBinary(image);
  assert.deepEqual(decodeBinary(wire), image);
  for (const size of [0, 4, 7, 8, wire.length - 80]) assert.throws(() => decodeBinary(wire.subarray(0, size)));
  const badMagic = Buffer.from(wire); badMagic[0] = 0;
  assert.throws(() => decodeBinary(badMagic));
  const highBit = Buffer.from(wire); highBit[0] |= 128;
  assert.throws(() => decodeBinary(highBit));
  const badLength = Buffer.from(wire); badLength.writeUInt32BE(513, 4);
  assert.throws(() => decodeBinary(badLength));
  assert.throws(() => decodeBinary(Buffer.alloc(maxBinary + 1)));
  assert.throws(() => encodeBinary({ ...image, transfer: 'invalid' }));
  const extraHeader = Buffer.from(JSON.stringify({ version: 1, channel, transfer: image.transfer, expires: image.expires, extra: true }));
  const prefix = Buffer.alloc(8); prefix.write('PSB1'); prefix.writeUInt32BE(extraHeader.length, 4);
  assert.throws(() => decodeBinary(Buffer.concat([prefix, extraHeader, Buffer.alloc(80)])));
  const large = { ...image, ciphertext: Buffer.alloc(8 * 1024 * 1024 + 28).toString('base64') };
  assert.deepEqual(decodeBinary(encodeBinary(large)), large);
});

for (const binaryUpload of [false, true]) for (const binaryDownload of [false, true]) {
  for (const waitingPoll of [false, true]) {
    test(`compatibility upload=${binaryUpload} download=${binaryDownload} waitingPoll=${waitingPoll}`, async () => {
      await fixture(async request => {
        const headers = binaryDownload ? { Accept: binaryType } : {};
        let poll;
        if (waitingPoll) {
          poll = request('/next', receiveToken, undefined, headers);
          await new Promise(resolve => setTimeout(resolve, 10));
        } else await request('/next', receiveToken);
        const image = envelope();
        const upload = request(`/transfers/${image.transfer}`, uploadToken,
          binaryUpload ? encodeBinary(image) : image,
          binaryUpload ? { 'Content-Type': binaryType } : {});
        if (!waitingPoll) {
          await new Promise(resolve => setTimeout(resolve, 10));
          poll = request('/next', receiveToken, undefined, headers);
        }
        const next = await poll;
        assert.equal(next.status, 200);
        assert.equal(next.headers.get('content-type'), binaryDownload ? binaryType : 'application/json');
        assert.deepEqual(binaryDownload ? decodeBinary(Buffer.from(await next.arrayBuffer())) : await next.json(), image);
        await request(`/transfers/${image.transfer}/receipt`, receiveToken, { receipt: 'opaque' });
        assert.deepEqual(await (await upload).json(), { receipt: 'opaque' });
      });
    });
  }
}

test('binary uploads reject malformed data and mismatched identity without fallback', async () => {
  await fixture(async request => {
    await request('/next', receiveToken);
    const image = envelope();
    const headers = { 'Content-Type': binaryType };
    assert.equal((await request(`/transfers/${image.transfer}`, uploadToken, Buffer.from('cleartext'), headers)).status, 400);
    assert.equal((await request(`/transfers/${randomUUID()}`, uploadToken, encodeBinary(image), headers)).status, 400);
    assert.equal((await request(`/transfers/${image.transfer}`, uploadToken, encodeBinary({ ...image, expires: 1 }), headers)).status, 400);
    assert.equal((await request(`/transfers/${image.transfer}`, uploadToken, encodeBinary(image), { ...headers, 'Content-Encoding': 'gzip' })).status, 415);
  });
});

test('diagnostics correlate upload forwarding receipt and redact payloads and credentials', async () => {
  const events = [];
  const image = envelope();
  await fixture(async request => {
    await request('/next', receiveToken);
    const upload = request(`/transfers/${image.transfer}`, uploadToken, image);
    await new Promise(resolve => setTimeout(resolve, 10));
    await request('/next', receiveToken);
    await request(`/transfers/${image.transfer}/receipt`, receiveToken, { receipt: 'private-ack' });
    assert.equal((await upload).status, 200);
  }, events);
  for (const event of ['upload_headers', 'upload_body_read', 'forward_enqueued', 'forward_finished', 'receipt_received', 'upload_finished']) {
    assert.ok(events.some(item => item.event === event && item.transfer === image.transfer), event);
  }
  const serialized = JSON.stringify(events);
  for (const secret of [channel, uploadToken, receiveToken, image.ciphertext, 'private-ack']) assert.ok(!serialized.includes(secret));
  assert.ok(events.every(item => item.elapsed_ms >= 0));
});

test('a broken diagnostics sink never breaks relay health or offline rejection', async () => {
  const server = createRelay({ channels: [{ channel, uploadToken, receiveToken }] }, {
    diagnostic: () => { throw new Error('logging unavailable'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    const image = envelope();
    assert.equal((await fetch(`${base}/v1/${channel}/transfers/${image.transfer}`, {
      method: 'POST', headers: { Authorization: `Bearer ${uploadToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(image)
    })).status, 503);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});

test('diagnostics include offline and timeout failures without request bodies', async () => {
  const events = [];
  await fixture(async request => {
    const offline = envelope();
    assert.equal((await request(`/transfers/${offline.transfer}`, uploadToken, offline)).status, 503);
    await request('/next', receiveToken);
    const late = envelope();
    assert.equal((await request(`/transfers/${late.transfer}`, uploadToken, late)).status, 504);
  }, events);
  assert.ok(events.some(item => item.event === 'upload_finished' && item.status === 503));
  assert.ok(events.some(item => item.event === 'upload_finished' && item.status === 504));
});

test('credentials are separated and offline receivers do not accept uploads', async () => {
  await fixture(async request => {
    assert.equal((await request('/next', uploadToken)).status, 401);
    const image = envelope();
    assert.equal((await request(`/transfers/${image.transfer}`, receiveToken, image)).status, 401);
    assert.equal((await request(`/transfers/${image.transfer}`, uploadToken, image)).status, 503);
  });
});

test('only ciphertext flows through the server; upload waits for receipt', async () => {
  await fixture(async request => {
    assert.equal((await request('/next', receiveToken)).status, 204);
    const image = envelope();
    const upload = request(`/transfers/${image.transfer}`, uploadToken, image);
    await new Promise(resolve => setTimeout(resolve, 10));
    const next = await request('/next', receiveToken);
    assert.deepEqual(await next.json(), image);
    assert.equal((await request(`/transfers/${image.transfer}/receipt`, uploadToken, { receipt: 'opaque' })).status, 401);
    assert.equal((await request(`/transfers/${image.transfer}/receipt`, receiveToken, { receipt: 'opaque' })).status, 200);
    const result = await upload;
    assert.equal(result.status, 200);
    assert.deepEqual(await result.json(), { receipt: 'opaque' });
  });
});

test('expired, oversized, plaintext and unacknowledged uploads fail closed', async () => {
  await fixture(async (request, oversizedHeaders) => {
    await request('/next', receiveToken);
    const old = envelope(); old.expires -= 200;
    assert.equal((await request(`/transfers/${old.transfer}`, uploadToken, old)).status, 400);
    const clear = envelope(); clear.image = 'must not be accepted';
    assert.equal((await request(`/transfers/${clear.transfer}`, uploadToken, clear)).status, 400);
    const huge = envelope();
    assert.equal(await oversizedHeaders(`/transfers/${huge.transfer}`), 413);
    const image = envelope();
    assert.equal((await request(`/transfers/${image.transfer}`, uploadToken, image)).status, 504);
  });
});

test('one pending image per channel and no decryption key in server config', async () => {
  assert.throws(() => createRelay({ channels: [{ channel, uploadToken, receiveToken, secret: 'not allowed' }] }));
  await fixture(async request => {
    await request('/next', receiveToken);
    const first = envelope();
    const upload = request(`/transfers/${first.transfer}`, uploadToken, first);
    await new Promise(resolve => setTimeout(resolve, 10));
    const second = envelope();
    assert.equal((await request(`/transfers/${second.transfer}`, uploadToken, second)).status, 409);
    assert.equal((await upload).status, 504);
  });
});
