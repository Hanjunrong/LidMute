import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  RETRY_ALARM_NAME,
  RETRY_STATE_KEY,
  createOutboxController,
  createRetryScheduler,
  replayOutbox,
  toAudibleFrame
} from './service-worker.mjs';

function deferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}

function storageWith(outbox, getGate) {
  let value = { sessionId: crypto.randomUUID(), seq: outbox.length, outbox };
  return {
    session: {
      async get() {
        if (getGate) await getGate.promise;
        return structuredClone(value);
      },
      async set(patch) { value = { ...value, ...structuredClone(patch) }; }
    },
    snapshot: () => structuredClone(value)
  };
}

function keyValueStorage(initial = {}) {
  let value = structuredClone(initial);
  return {
    area: {
      async get(keys) {
        const requested = Array.isArray(keys) ? keys : [keys];
        return Object.fromEntries(
          requested.filter((key) => Object.hasOwn(value, key)).map((key) => [key, structuredClone(value[key])])
        );
      },
      async set(patch) { value = { ...value, ...structuredClone(patch) }; },
      async remove(key) { delete value[key]; }
    },
    snapshot: () => structuredClone(value)
  };
}

function alarmHarness() {
  const alarms = new Map();
  return {
    api: {
      async get(name) { return alarms.get(name); },
      create(name, info) { alarms.set(name, { name, ...structuredClone(info) }); },
      async clear(name) { return alarms.delete(name); }
    },
    get: (name) => structuredClone(alarms.get(name)),
    dropAll: () => alarms.clear()
  };
}

test('serializes a Chrome audible event with tab-level evidence', () => {
  const frame = toAudibleFrame({
    id: 483, windowId: 12, index: 4, title: '优酷 - 为好内容全力以赴',
    url: 'https://v.youku.com/v_show/id_example', status: 'complete', audible: true,
    mutedInfo: { muted: false }, active: false, pinned: true, incognito: false
  }, 'session-1', 42);

  assert.equal(frame.type, 'tab_audio_started');
  assert.equal(frame.tab.tabId, 483);
  assert.equal(frame.tab.url, 'https://v.youku.com/v_show/id_example');
  assert.equal(frame.tab.audible, true);
  assert.equal(frame.seq, '42');
});

test('replays every retained event through the outbox replay helper', () => {
  const posted = [];
  replayOutbox([{ eventId: 'one' }, { eventId: 'two' }], (event) => posted.push(event.eventId));
  assert.deepEqual(posted, ['one', 'two']);
});

test('serializes crossed acknowledgements without resurrecting either event', async () => {
  const gate = deferred();
  const storage = storageWith([{ eventId: 'one' }, { eventId: 'two' }], gate);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  const first = controller.acknowledge({ type: 'ack', eventId: 'one', disposition: 'accepted' });
  const second = controller.acknowledge({ type: 'ack', eventId: 'two', disposition: 'duplicate' });
  gate.resolve();
  await Promise.all([first, second]);
  assert.deepEqual(storage.snapshot().outbox, []);
});

test('removes only terminal dispositions and keeps retryable failure', async () => {
  for (const disposition of ['accepted', 'duplicate', 'ignored_incognito', 'rejected_permanent']) {
    const storage = storageWith([{ eventId: disposition }]);
    const controller = createOutboxController(storage.session, () => {}, () => {});
    await controller.acknowledge({ type: 'ack', eventId: disposition, disposition });
    assert.deepEqual(storage.snapshot().outbox, []);
  }
  const storage = storageWith([{ eventId: 'retry' }]);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  await controller.acknowledge({ type: 'ack', eventId: 'retry', disposition: 'retryable_failure' });
  assert.equal(storage.snapshot().outbox.length, 1);
});

test('enqueue concurrent with ack preserves the new item', async () => {
  const storage = storageWith([{ eventId: 'old' }]);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  await Promise.all([
    controller.acknowledge({ type: 'ack', eventId: 'old', disposition: 'accepted' }),
    controller.enqueue({ eventId: 'new' })
  ]);
  assert.deepEqual(storage.snapshot().outbox.map((item) => item.eventId), ['new']);
});

test('flush replays in order without deleting before acknowledgements', async () => {
  const storage = storageWith([{ eventId: 'one' }, { eventId: 'two' }]);
  const posted = [];
  const controller = createOutboxController(storage.session, (item) => posted.push(item.eventId), () => {});
  await controller.flush();
  await controller.flush();
  assert.deepEqual(posted, ['one', 'two', 'one', 'two']);
  assert.deepEqual(storage.snapshot().outbox.map((item) => item.eventId), ['one', 'two']);
});

test('duplicate and out-of-order terminal acks converge to an empty outbox', async () => {
  const storage = storageWith([{ eventId: 'one' }, { eventId: 'two' }]);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  await Promise.all([
    controller.acknowledge({ type: 'ack', eventId: 'two', disposition: 'accepted' }),
    controller.acknowledge({ type: 'ack', eventId: 'one', disposition: 'accepted' }),
    controller.acknowledge({ type: 'ack', eventId: 'two', disposition: 'duplicate' })
  ]);
  assert.deepEqual(storage.snapshot().outbox, []);
});

test('manifest grants alarms permission for suspension-safe retry', async () => {
  const manifest = JSON.parse(await readFile(new URL('./manifest.json', import.meta.url)));
  assert.equal(manifest.permissions.includes('alarms'), true);
});

test('retry persists its deadline and rebuilds a lost alarm after worker restart', async () => {
  const storage = keyValueStorage();
  const alarms = alarmHarness();
  const clock = { now: 10_000 };
  const firstWorker = createRetryScheduler(
    storage.area,
    alarms.api,
    async () => {},
    () => clock.now
  );

  await firstWorker.schedule();
  const persisted = storage.snapshot()[RETRY_STATE_KEY];
  assert.equal(persisted.deadlineMilliseconds, 11_000);
  assert.equal(persisted.nextDelayMilliseconds, 2_000);
  assert.equal(alarms.get(RETRY_ALARM_NAME).when, 11_000);

  alarms.dropAll(); // browser/session alarm loss while durable retry state remains
  const restartedWorker = createRetryScheduler(
    storage.area,
    alarms.api,
    async () => {},
    () => clock.now
  );
  await restartedWorker.restore();

  assert.equal(alarms.get(RETRY_ALARM_NAME).when, 11_000);
  assert.deepEqual(storage.snapshot()[RETRY_STATE_KEY], persisted);
});

test('alarm wake clears the old deadline before reconnecting and keeps backoff across suspension', async () => {
  const storage = keyValueStorage();
  const alarms = alarmHarness();
  const clock = { now: 20_000 };
  const observed = [];
  let restartedWorker;
  const firstWorker = createRetryScheduler(
    storage.area,
    alarms.api,
    async () => {},
    () => clock.now
  );
  await firstWorker.schedule();

  restartedWorker = createRetryScheduler(
    storage.area,
    alarms.api,
    async () => {
      observed.push(storage.snapshot()[RETRY_STATE_KEY]);
      await restartedWorker.schedule();
    },
    () => clock.now
  );
  clock.now = 21_000;
  await restartedWorker.fire({ name: RETRY_ALARM_NAME });

  assert.deepEqual(observed, [{ nextDelayMilliseconds: 2_000 }]);
  assert.equal(storage.snapshot()[RETRY_STATE_KEY].deadlineMilliseconds, 23_000);
  assert.equal(storage.snapshot()[RETRY_STATE_KEY].nextDelayMilliseconds, 4_000);
  assert.equal(alarms.get(RETRY_ALARM_NAME).when, 23_000);
});

test('terminal acknowledgement clears retry state and alarm and resets capped backoff', async () => {
  const storage = keyValueStorage({
    [RETRY_STATE_KEY]: {
      deadlineMilliseconds: 65_000,
      nextDelayMilliseconds: 60_000
    }
  });
  const alarms = alarmHarness();
  alarms.api.create(RETRY_ALARM_NAME, { when: 65_000 });
  const scheduler = createRetryScheduler(storage.area, alarms.api, async () => {}, () => 5_000);

  await scheduler.succeed();
  assert.equal(storage.snapshot()[RETRY_STATE_KEY], undefined);
  assert.equal(alarms.get(RETRY_ALARM_NAME), undefined);

  await scheduler.schedule();
  assert.equal(storage.snapshot()[RETRY_STATE_KEY].deadlineMilliseconds, 6_000);
  assert.equal(storage.snapshot()[RETRY_STATE_KEY].nextDelayMilliseconds, 2_000);
});

test('retry backoff never grows beyond sixty seconds', async () => {
  const storage = keyValueStorage({
    [RETRY_STATE_KEY]: { nextDelayMilliseconds: 60_000 }
  });
  const alarms = alarmHarness();
  const scheduler = createRetryScheduler(storage.area, alarms.api, async () => {}, () => 100_000);

  await scheduler.schedule();

  assert.equal(storage.snapshot()[RETRY_STATE_KEY].deadlineMilliseconds, 160_000);
  assert.equal(storage.snapshot()[RETRY_STATE_KEY].nextDelayMilliseconds, 60_000);
});
