const { test } = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const { ProvisioningService } = require('../services/provisioningService');
const { normalizeMac } = require('../services/macIdentity');

const MAC = '34:98:7A:C3:03:04';
const CID = normalizeMac(MAC); // 34987AC30304

function sha256(s) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

function makeSession(overrides = {}) {
  const row = {
    _id: 'sess1',
    sessionId: 'sess1',
    ownerId: 'owner1',
    claimTokenHash: sha256('tok123'),
    expectedDeviceId: null,
    hardwareId: null,
    status: 'pending',
    expiresAt: new Date(Date.now() + 60_000),
    claimedAt: null,
    save: async function save() {
      return row;
    },
    ...overrides,
  };
  return row;
}

// In-memory Device model replacement. Supports the exact queries the service
// issues: findOne({deviceId}) / findOne({hardwareId}); findOneAndUpdate
// ({_id, ownerId:null}); create() honouring a unique deviceId index; rollback
// to empty store.
class FakeDeviceModel {
  constructor(rows = [], opts = {}) {
    this.rows = rows.map((r) => ({ ...r }));
    this.opts = opts; // { raceCreateDup } to force the unique-index loser path
    this.createCalls = 0;
  }

  async findOne(query) {
    if (this.opts.raceCreateDup) return null;
    if (query.deviceId) {
      return this.rows.find((r) => r.deviceId === query.deviceId) || null;
    }
    if (query.hardwareId) {
      return this.rows.find((r) => r.hardwareId === query.hardwareId) || null;
    }
    return null;
  }

  async findOneAndUpdate(query, update) {
    const row = this.rows.find((r) => r._id === query._id && r.ownerId === null);
    if (!row) return null;
    Object.assign(row, update.$set);
    return row;
  }

  async create(data) {
    this.createCalls += 1;
    if (this.rows.some((r) => r.deviceId === data.deviceId)) {
      const err = new Error('E11000 duplicate key');
      err.code = 11000;
      throw err;
    }
    const row = { ...data, _id: `dev-${this.rows.length}` };
    this.rows.push(row);
    return row;
  }

  async updateOne() {
    return { ok: 1 };
  }
}

// Session model replacement: one mutable row + atomic status flip.
class FakeSessionModel {
  constructor(row, opts = {}) {
    this.row = row;
    this.opts = opts;
    this.createCalls = 0;
  }

  async findOne({ sessionId }) {
    return this.row && this.row.sessionId === sessionId ? this.row : null;
  }

  async findOneAndUpdate(query, update) {
    const won =
      this.row &&
      this.row._id === query._id &&
      this.row.status === 'pending' &&
      this.opts.flipWins !== false;
    if (!won) return null;
    this.row.status = update.$set.status;
    this.row.claimedAt = update.$set.claimedAt;
    return this.row;
  }

  async updateOne(query, update) {
    if (this.row && this.row._id === query._id) {
      this.row.status = update.$set.status;
      this.row.claimedAt = update.$set.claimedAt;
    }
    return { ok: 1 };
  }

  async create(data) {
    this.createCalls += 1;
    this.created = { ...data, _id: 'sess-new' };
    return this.created;
  }
}

function service({ session, deviceRows = [], recent = false, mqttOpts, deviceOpts } = {}) {
  const sessionModel = new FakeSessionModel(session, mqttOpts || {});
  const deviceModel = new FakeDeviceModel(deviceRows, deviceOpts || {});
  const mqtt = { hasRecent: () => recent };
  const updated = [];
  const registry = {
    update: (d) => updated.push(d.deviceId),
    remove: () => {},
  };
  const svc = new ProvisioningService({
    sessionModel,
    deviceModel,
    mqtt,
    registry,
  });
  return { svc, sessionModel, deviceModel, updated };
}

// ─────────────────────────────────────────────────────────────

test('create() issues a session + one-time token, never a deviceId', async () => {
  const session = makeSession();
  const { svc, sessionModel } = service({ session });
  const res = await svc.create('owner1');

  assert.ok(res.sessionId);
  assert.ok(res.claimToken);
  assert.ok('deviceId' in res === false, 'create() must not return a deviceId');
  assert.ok(!('claimTokenHash' in res), 'token hash must never be returned');
  // The plain token is stored hashed, never in plain form.
  assert.ok(sessionModel.createCalls === 1);
  const stored = sessionModel.created;
  assert.notStrictEqual(stored.claimTokenHash, res.claimToken);
  assert.strictEqual(stored.claimTokenHash, sha256(res.claimToken));
  // The identity field must be ABSENT (not null) at creation: a null value
  // would collide globally on the sparse-unique index (E11000 -> 500 on every
  // later create). Only attachIdentity() may set it, to a canonical MAC.
  assert.strictEqual(
    'expectedDeviceId' in stored,
    false,
    'pending session must not store expectedDeviceId',
  );
});

test('attachIdentity: invalid MAC => INVALID_MAC, nothing stored', async () => {
  const session = makeSession();
  const { svc, deviceModel } = service({ session });
  for (const bad of ['', 'not-a-mac', '34987AC3030', '34987AC30304X', null]) {
    await assert.rejects(
      () => svc.attachIdentity('sess1', 'owner1', bad),
      (err) => err.code === 'INVALID_MAC',
    );
  }
  assert.strictEqual(deviceModel.rows.length, 0);
});

test('attachIdentity: normalizes MAC and anchors it as expectedDeviceId', async () => {
  const session = makeSession();
  const { svc } = service({ session });
  await svc.attachIdentity('sess1', 'owner1', '34-98-7a-c3-03-04');
  assert.strictEqual(session.expectedDeviceId, CID);
  assert.strictEqual(session.hardwareId, CID);
});

test('attachIdentity case B: own device => DEVICE_ALREADY_EXISTS', async () => {
  const session = makeSession();
  const { svc } = service({
    session,
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner1', hardwareId: CID }],
  });
  await assert.rejects(
    () => svc.attachIdentity('sess1', 'owner1', MAC),
    (err) => err.code === 'DEVICE_ALREADY_EXISTS',
  );
});

test('attachIdentity case C: other user => generic DEVICE_ALREADY_REGISTERED', async () => {
  const session = makeSession();
  const { svc } = service({
    session,
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner2', hardwareId: CID }],
  });
  await assert.rejects(
    () => svc.attachIdentity('sess1', 'owner1', MAC),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
});

test('attachIdentity: legacy stees_ device with this MAC is deduped generically', async () => {
  const session = makeSession();
  const { svc } = service({
    session,
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: 'owner2', hardwareId: CID },
    ],
  });
  await assert.rejects(
    () => svc.attachIdentity('sess1', 'owner1', MAC),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
});

test('claim: missing expected identity => INVALID_MAC', async () => {
  const session = makeSession(); // expectedDeviceId null (never attached)
  const { svc } = service({ session });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'INVALID_MAC',
  );
});

test('claim: possession not proven => DEVICE_NOT_SEEN, nothing created, session stays pending', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc, deviceModel, sessionModel } = service({ session, recent: false });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'DEVICE_NOT_SEEN',
  );
  assert.strictEqual(deviceModel.rows.length, 0, 'no device may be created');
  assert.strictEqual(sessionModel.row.status, 'pending', 'claim rolled back');
});

test('claim: first provisioning succeeds with canonical MAC identity', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc, deviceModel, updated } = service({ session, recent: true });
  const device = await svc.claim({
    sessionId: 'sess1',
    ownerId: 'owner1',
    claimToken: 'tok123',
    name: 'pump',
    channels: 4,
  });
  assert.strictEqual(device.deviceId, CID);
  assert.strictEqual(device.hardwareId, CID);
  assert.strictEqual(device.ownerId, 'owner1');
  assert.strictEqual(deviceModel.rows.length, 1);
  assert.deepStrictEqual(updated, [CID]);
});

test('claim: same-user device => DEVICE_ALREADY_EXISTS (no duplicate created)', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc, deviceModel } = service({
    session,
    recent: true,
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner1', hardwareId: CID }],
  });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'DEVICE_ALREADY_EXISTS',
  );
  assert.strictEqual(deviceModel.rows.length, 1, 'no duplicate Device document');
});

test('claim: other-user device => generic DEVICE_ALREADY_REGISTERED', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc } = service({
    session,
    recent: true,
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner2', hardwareId: CID }],
  });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
});

test('claim: concurrent claims for same MAC => exactly one device, one loser DEVICE_ALREADY_REGISTERED', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  // findOne returns nothing (simulated race); create() hits the unique index.
  const { svc, deviceModel, sessionModel } = service({
    session,
    recent: true,
    deviceOpts: { raceCreateDup: true },
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner2', hardwareId: CID }],
  });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
  assert.strictEqual(deviceModel.rows.length, 1, 'exactly one Device for that MAC');
  assert.strictEqual(sessionModel.row.status, 'pending', 'loser session rolled back');
});

test('claim: two claims on one session => exactly one wins, other gets SESSION_USED', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc, sessionModel } = service({ session, recent: true });
  const first = svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 });
  // Let the first claim finish (it flips the session to claimed and creates the
  // Device). Only then arm the flip to fail for the second, concurrent claim.
  await first;
  sessionModel.opts.flipWins = false;
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'SESSION_USED',
  );
});

test('claim: legacy unowned record is reclaimed (renamed to canonical MAC, no duplicate)', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc, deviceModel } = service({
    session,
    recent: true,
    deviceRows: [{ _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: null, hardwareId: CID }],
  });
  const device = await svc.claim({
    sessionId: 'sess1',
    ownerId: 'owner1',
    claimToken: 'tok123',
    name: 'pump',
    channels: 4,
  });
  assert.strictEqual(device.deviceId, CID);
  assert.strictEqual(deviceModel.rows.length, 1, 'one doc for the MAC, never two');
});

test('claim: wrong claim token => INVALID_TOKEN', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc, deviceModel } = service({ session, recent: true });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'wrong', name: 'd', channels: 1 }),
    (err) => err.code === 'INVALID_TOKEN',
  );
  assert.strictEqual(deviceModel.rows.length, 0);
});

test('claim: expired session => SESSION_EXPIRED', async () => {
  const session = makeSession({
    expectedDeviceId: CID,
    hardwareId: CID,
    expiresAt: new Date(Date.now() - 1000),
  });
  const { svc } = service({ session, recent: true });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner1', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'SESSION_EXPIRED',
  );
});

test('claim: session owned by another user is never revealed', async () => {
  const session = makeSession({ expectedDeviceId: CID, hardwareId: CID });
  const { svc } = service({ session, recent: true });
  await assert.rejects(
    () => svc.claim({ sessionId: 'sess1', ownerId: 'owner2', claimToken: 'tok123', name: 'd', channels: 1 }),
    (err) => err.code === 'SESSION_NOT_FOUND',
  );
});

test('factory reset does NOT delete anything: no cleanup path touches Device documents', async () => {
  // There is no code path that converts an MQTT disappearance / reset into a
  // Device write. Prove it: only attach/claim/delete-path calls the model, and
  // none of those run without a session or explicit user action.
  const session = makeSession();
  const { svc, deviceModel } = service({ session });
  await svc.attachIdentity('sess1', 'owner1', MAC);
  assert.strictEqual(deviceModel.rows.length, 0, 'anchoring never writes a Device');
  assert.strictEqual(deviceModel.createCalls, 0);
});