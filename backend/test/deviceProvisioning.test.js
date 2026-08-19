const { test } = require('node:test');
const assert = require('node:assert');
const jwt = require('jsonwebtoken');
const { DeviceProvisioningService } = require('../services/deviceProvisioningService');
const { normalizeMac } = require('../services/macIdentity');
const { authMiddleware, JWT_SECRET } = require('../middleware/auth');

const MAC = '34:98:7A:C3:03:04';
const CID = normalizeMac(MAC); // 34987AC30304

// In-memory Device model replacement. Supports the exact queries the service
// issues: findOne({deviceId}) / findOne({hardwareId}); findOneAndUpdate
// ({_id, ownerId:null}); create() honouring a unique deviceId index.
class FakeDeviceModel {
  constructor(rows = [], opts = {}) {
    this.rows = rows.map((r) => ({ ...r }));
    this.opts = opts; // { raceCreateDup } to force the unique-index loser path
    this.createCalls = 0;
    this.updateOneCalls = [];
  }

  async updateOne(filter, update, options) {
    this.updateOneCalls.push({ filter, update, options });
    const row = this.rows.find((r) => r.deviceId === filter.deviceId);
    if (row && update && update.$set) Object.assign(row, update.$set);
    return { catch() {} };
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
}

function service({
  deviceRows = [],
  recent = false,
  deviceOpts,
  syncFor,
  unclaimedIpHint,
} = {}) {
  const deviceModel = new FakeDeviceModel(deviceRows, deviceOpts || {});
  const mqtt = { hasRecent: () => recent };
  if (syncFor) mqtt.requestStateSyncFor = syncFor;
  if (unclaimedIpHint) mqtt.unclaimedIpHint = () => unclaimedIpHint;
  const updated = [];
  const ipSeeds = [];
  const registry = {
    update: (d) => updated.push(d.deviceId),
    updateIp: (deviceId, ip) => ipSeeds.push({ deviceId, ip }),
    remove: () => {},
  };
  const runtimeState = {
    ensured: [],
    touched: [],
    ensureDeviceState(deviceId, channels) {
      this.ensured.push(deviceId);
      return {};
    },
    touchDevice(deviceId) {
      this.touched.push(deviceId);
    },
  };
  const svc = new DeviceProvisioningService({
    deviceModel,
    mqtt,
    registry,
    runtimeState,
  });
  return { svc, deviceModel, updated, ipSeeds, runtimeState };
}

function provision(svc, overrides = {}) {
  return svc.provision({
    ownerId: 'owner1',
    deviceId: MAC,
    name: 'Garden Pump',
    channels: 4,
    ...overrides,
  });
}

// ─────────────────────────────────────────────────────────────

test('valid MAC + recently seen => device created with canonical MAC identity', async () => {
  const { svc, deviceModel, updated } = service({ recent: true });
  const device = await provision(svc);
  assert.strictEqual(device.deviceId, CID);
  assert.strictEqual(device.hardwareId, CID);
  assert.strictEqual(device.ownerId, 'owner1');
  assert.strictEqual(deviceModel.rows.length, 1);
  assert.deepStrictEqual(updated, [CID]);
});

test('fresh claim warms runtimeState so control works without a restart', async () => {
  const syncs = [];
  const { svc, runtimeState } = service({ recent: true, syncFor: (id) => syncs.push(id) });
  await provision(svc);
  // synchronous warmth -> isOnline gate in control.js passes immediately
  assert.deepStrictEqual(runtimeState.ensured, [CID]);
  assert.deepStrictEqual(runtimeState.touched, [CID]);
  // async state sync requested for the canonical MAC, not the raw input
  assert.deepStrictEqual(syncs, [CID]);
});

test('reclaimed legacy device also warms runtimeState', async () => {
  const { svc, runtimeState } = service({
    recent: true,
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: null, hardwareId: CID },
    ],
  });
  await provision(svc);
  assert.deepStrictEqual(runtimeState.ensured, [CID]);
  assert.deepStrictEqual(runtimeState.touched, [CID]);
});

test('claim without a stateSyncFor implementation still warms runtimeState', async () => {
  const { svc, runtimeState } = service({ recent: true });
  await provision(svc);
  assert.deepStrictEqual(runtimeState.ensured, [CID]);
  assert.deepStrictEqual(runtimeState.touched, [CID]);
});

test('new device uses the MAC as deviceId (no backend-issued id, no session)', async () => {
  const { svc, deviceModel } = service({ recent: true });
  const device = await provision(svc, { deviceId: '34-98-7a-c3-03-04' });
  assert.strictEqual(device.deviceId, CID);
  assert.strictEqual(deviceModel.rows[0].deviceId, CID);
});

test('invalid MAC => INVALID_MAC, nothing created', async () => {
  const { svc, deviceModel } = service({ recent: true });
  for (const bad of ['', 'not-a-mac', '34987AC3030', '34987AC30304X', null, 'stees_0123456789abcdef']) {
    await assert.rejects(
      () => provision(svc, { deviceId: bad }),
      (err) => err.code === 'INVALID_MAC',
    );
  }
  assert.strictEqual(deviceModel.rows.length, 0);
});

test('invalid channels => BAD_CHANNELS, nothing created', async () => {
  const { svc, deviceModel } = service({ recent: true });
  for (const bad of [0, -1, 17, 1.5, 'x']) {
    await assert.rejects(
      () => provision(svc, { channels: bad }),
      (err) => err.code === 'BAD_CHANNELS',
    );
  }
  assert.strictEqual(deviceModel.rows.length, 0);
});

test('invalid name => BAD_NAME, nothing created', async () => {
  const { svc, deviceModel } = service({ recent: true });
  for (const bad of ['', '   ', null]) {
    await assert.rejects(
      () => provision(svc, { name: bad }),
      (err) => err.code === 'BAD_NAME',
    );
  }
  assert.strictEqual(deviceModel.rows.length, 0);
});

test('device not recently seen => DEVICE_NOT_SEEN, nothing created', async () => {
  const { svc, deviceModel } = service({ recent: false });
  await assert.rejects(
    () => provision(svc),
    (err) => err.code === 'DEVICE_NOT_SEEN',
  );
  assert.strictEqual(deviceModel.rows.length, 0, 'no device may be created');
});

test('same-user duplicate => DEVICE_ALREADY_EXISTS (no duplicate created)', async () => {
  const { svc, deviceModel } = service({
    recent: true,
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner1', hardwareId: CID }],
  });
  await assert.rejects(
    () => provision(svc),
    (err) => err.code === 'DEVICE_ALREADY_EXISTS',
  );
  assert.strictEqual(deviceModel.rows.length, 1, 'no duplicate Device document');
});

test('other-user duplicate => generic DEVICE_ALREADY_REGISTERED', async () => {
  const { svc } = service({
    recent: true,
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner2', hardwareId: CID }],
  });
  await assert.rejects(
    () => provision(svc),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
});

test('legacy stees_ device owned by another user with this MAC is deduped generically', async () => {
  const { svc } = service({
    recent: true,
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: 'owner2', hardwareId: CID },
    ],
  });
  await assert.rejects(
    () => provision(svc),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
});

test('legacy stees_ device owned by the SAME user => DEVICE_ALREADY_EXISTS', async () => {
  const { svc } = service({
    recent: true,
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: 'owner1', hardwareId: CID },
    ],
  });
  await assert.rejects(
    () => provision(svc),
    (err) => err.code === 'DEVICE_ALREADY_EXISTS',
  );
});

test('legacy unowned record is reclaimed (renamed to canonical MAC, no duplicate)', async () => {
  const { svc, deviceModel } = service({
    recent: true,
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: null, hardwareId: CID },
    ],
  });
  const device = await provision(svc);
  assert.strictEqual(device.deviceId, CID);
  assert.strictEqual(deviceModel.rows.length, 1, 'one doc for the MAC, never two');
});

test('concurrent registrations for same MAC => exactly one device, loser DEVICE_ALREADY_REGISTERED', async () => {
  // findOne returns nothing (simulated race); create() hits the unique index.
  const { svc, deviceModel } = service({
    recent: true,
    deviceOpts: { raceCreateDup: true },
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner2', hardwareId: CID }],
  });
  await assert.rejects(
    () => provision(svc),
    (err) => err.code === 'DEVICE_ALREADY_REGISTERED',
  );
  assert.strictEqual(deviceModel.rows.length, 1, 'exactly one Device for that MAC');
});

test('preflight /check: not_found when MAC is unregistered', async () => {
  const { svc } = service({ recent: false });
  const result = await svc.preflightCheck({ ownerId: 'owner1', deviceId: MAC });
  assert.deepStrictEqual(result, { status: 'not_found' });
});

test('preflight /check: mine when MAC already owns by the caller', async () => {
  const { svc } = service({
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner1', hardwareId: CID }],
  });
  const result = await svc.preflightCheck({ ownerId: 'owner1', deviceId: MAC });
  assert.deepStrictEqual(result, { status: 'mine' });
});

test('preflight /check: others when MAC owned by another account (ownership hidden)', async () => {
  const { svc } = service({
    deviceRows: [{ _id: 'd1', deviceId: CID, ownerId: 'owner2', hardwareId: CID }],
  });
  const result = await svc.preflightCheck({ ownerId: 'owner1', deviceId: MAC });
  assert.deepStrictEqual(result, { status: 'others' });
});

test('preflight /check: legacy stees_ same-account => mine', async () => {
  const { svc } = service({
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: 'owner1', hardwareId: CID },
    ],
  });
  const result = await svc.preflightCheck({ ownerId: 'owner1', deviceId: MAC });
  assert.deepStrictEqual(result, { status: 'mine' });
});

test('preflight /check: legacy unowned record => not_found (re-claimable)', async () => {
  const { svc } = service({
    deviceRows: [
      { _id: 'legacy', deviceId: 'stees_0123456789abcdef', ownerId: null, hardwareId: CID },
    ],
  });
  const result = await svc.preflightCheck({ ownerId: 'owner1', deviceId: MAC });
  assert.deepStrictEqual(result, { status: 'not_found' });
});

test('preflight /check: invalid MAC => INVALID_MAC', async () => {
  const { svc } = service();
  for (const bad of ['', 'not-a-mac', 'stees_0123456789abcdef', null]) {
    await assert.rejects(
      () => svc.preflightCheck({ ownerId: 'owner1', deviceId: bad }),
      (err) => err.code === 'INVALID_MAC',
    );
  }
});

// ─────────────────────────────────────────────────────────────
// lastIp seeding from the device's own boot telemetry (unclaimed hint).
// A fresh claim has no lastIp yet — the IP the device reported in its boot
// STATE (see mqttGateway unclaimedIpHints) must seed it immediately so the
// app's local-setup bootstrap can reach the device without waiting up to a
// TelePeriod for the next post-claim STATE.
// ─────────────────────────────────────────────────────────────

test('fresh claim seeds lastIp from the unclaimed boot-telemetry hint', async () => {
  const { svc, deviceModel, ipSeeds } = service({
    recent: true,
    unclaimedIpHint: '192.168.1.33', // what the device reported at boot
  });
  const device = await provision(svc);
  assert.strictEqual(device.lastIp, '192.168.1.33',
    'the returned device must carry the seeded hint');
  assert.deepStrictEqual(ipSeeds, [{ deviceId: CID, ip: '192.168.1.33' }],
    'the registry must learn the seeded IP for the canonical MAC');
  assert.deepStrictEqual(deviceModel.updateOneCalls, [
    { filter: { deviceId: CID }, update: { $set: { lastIp: '192.168.1.33' } }, options: undefined },
  ], 'the DB row must persist the seeded lastIp');
});

test('claim never overwrites an existing lastIp with the hint', async () => {
  const { svc, deviceModel, ipSeeds } = service({
    recent: true,
    unclaimedIpHint: '192.168.1.33',
    deviceRows: [
      { _id: 'existing', deviceId: CID, ownerId: null, hardwareId: CID, lastIp: '10.0.0.5' },
    ],
  });
  const device = await provision(svc);
  assert.strictEqual(device.lastIp, '10.0.0.5',
    'an already-known lastIp must survive the claim untouched');
  assert.deepStrictEqual(ipSeeds, [],
    'no registry seed when the device already has a lastIp');
  assert.deepStrictEqual(deviceModel.updateOneCalls, [],
    'no DB write when the device already has a lastIp');
});

test('claim without a hint leaves lastIp null (no seed, no crash)', async () => {
  const { svc, deviceModel, ipSeeds } = service({ recent: true });
  const device = await provision(svc);
  assert.strictEqual(device.lastIp ?? null, null,
    'no hint => no seeded lastIp');
  assert.deepStrictEqual(ipSeeds, []);
  assert.deepStrictEqual(deviceModel.updateOneCalls, []);
});

test('authMiddleware: missing/bad/expired token => 401, valid token sets userId', async () => {
  const missing = { headers: {} };
  const res401 = { statusCode: 0, body: null, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; return this; } };
  authMiddleware(missing, res401, () => {});
  assert.strictEqual(res401.statusCode, 401);

  const bad = { headers: { authorization: 'Bearer not-a-jwt' } };
  const resBad = { statusCode: 0, status(c) { this.statusCode = c; return this; }, json() { return this; } };
  authMiddleware(bad, resBad, () => {});
  assert.strictEqual(resBad.statusCode, 401);

  const token = jwt.sign({ userId: 'owner1' }, JWT_SECRET, { expiresIn: '1h' });
  const ok = { headers: { authorization: `Bearer ${token}` } };
  let called = false;
  authMiddleware(ok, { status() { return this; }, json() { return this; } }, () => { called = true; });
  assert.strictEqual(ok.userId, 'owner1');
  assert.strictEqual(called, true);
});
