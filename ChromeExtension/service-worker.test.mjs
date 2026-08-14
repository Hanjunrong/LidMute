import assert from 'node:assert/strict';
import test from 'node:test';
import { createOutboxController, replayOutbox, toAudibleFrame } from './service-worker.mjs';

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
