const HOST_NAME = 'com.lidmute.nativehost';
const OUTBOX_LIMIT = 256;
const INITIAL_RETRY_DELAY_MILLISECONDS = 1_000;
const MAXIMUM_RETRY_DELAY_MILLISECONDS = 60_000;
const TERMINAL_DISPOSITIONS = new Set([
  'accepted', 'duplicate', 'ignored_incognito', 'rejected_permanent'
]);
export const RETRY_ALARM_NAME = 'lidmute-native-retry';
export const RETRY_STATE_KEY = 'nativeRetry';
let nativePort;
let outboxController;
let retryScheduler;

function runSafely(operation) {
  void Promise.resolve().then(operation).catch(() => {});
}

export function toAudibleFrame(tab, sessionId, seq) {
  return {
    v: 1,
    type: 'tab_audio_started',
    eventId: crypto.randomUUID(),
    extensionSessionId: sessionId,
    seq: String(seq),
    sentAt: new Date().toISOString(),
    tab: {
      windowId: tab.windowId,
      tabId: tab.id,
      index: tab.index,
      title: tab.title || '',
      url: tab.url || '',
      status: tab.status || 'unknown',
      audible: Boolean(tab.audible),
      muted: {
        value: Boolean(tab.mutedInfo?.muted),
        reason: tab.mutedInfo?.reason || null,
        extensionId: tab.mutedInfo?.extensionId || null
      },
      active: Boolean(tab.active),
      pinned: Boolean(tab.pinned),
      incognito: Boolean(tab.incognito)
    }
  };
}

export function replayOutbox(events, post) {
  for (const event of events) post(event);
}

function chromeRuntimeError() {
  if (typeof chrome === 'undefined') return undefined;
  return chrome.runtime?.lastError;
}

function getAlarm(alarms, name) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const complete = (value) => {
      if (settled) return;
      settled = true;
      const error = chromeRuntimeError();
      if (error) reject(new Error(error.message));
      else resolve(value);
    };
    try {
      const result = alarms.get(name, complete);
      if (result?.then) result.then(complete, reject);
    } catch (error) {
      reject(error);
    }
  });
}

function clearAlarm(alarms, name) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const complete = (value) => {
      if (settled) return;
      settled = true;
      const error = chromeRuntimeError();
      if (error) reject(new Error(error.message));
      else resolve(value);
    };
    try {
      const result = alarms.clear(name, complete);
      if (result?.then) result.then(complete, reject);
    } catch (error) {
      reject(error);
    }
  });
}

export function createRetryScheduler(storage, alarms, retry, now = Date.now) {
  let tail = Promise.resolve();
  const serial = (operation) => {
    const result = tail.then(operation, operation);
    tail = result.catch(() => {});
    return result;
  };

  async function state() {
    const stored = await storage.get([RETRY_STATE_KEY]);
    return stored[RETRY_STATE_KEY] ?? {};
  }

  function normalizedDelay(value) {
    if (!Number.isFinite(value) || value < INITIAL_RETRY_DELAY_MILLISECONDS) {
      return INITIAL_RETRY_DELAY_MILLISECONDS;
    }
    return Math.min(value, MAXIMUM_RETRY_DELAY_MILLISECONDS);
  }

  async function createAlarm(deadlineMilliseconds) {
    await Promise.resolve(alarms.create(RETRY_ALARM_NAME, { when: deadlineMilliseconds }));
  }

  async function ensureAlarm(deadlineMilliseconds) {
    const existing = await getAlarm(alarms, RETRY_ALARM_NAME);
    if (!existing) await createAlarm(deadlineMilliseconds);
  }

  async function prepareRetryAfterWake(stateBeforeWake) {
    const nextDelayMilliseconds = normalizedDelay(stateBeforeWake.nextDelayMilliseconds);
    await storage.set({ [RETRY_STATE_KEY]: { nextDelayMilliseconds } });
    try {
      await clearAlarm(alarms, RETRY_ALARM_NAME);
    } catch {
      // Reconnecting must not depend on removing an already-fired or stale alarm.
    }
  }

  return {
    schedule() {
      return serial(async () => {
        const current = await state();
        if (Number.isFinite(current.deadlineMilliseconds)) {
          await ensureAlarm(current.deadlineMilliseconds);
          return;
        }

        const delayMilliseconds = normalizedDelay(current.nextDelayMilliseconds);
        const deadlineMilliseconds = now() + delayMilliseconds;
        const nextDelayMilliseconds = Math.min(
          delayMilliseconds * 2,
          MAXIMUM_RETRY_DELAY_MILLISECONDS
        );
        await storage.set({
          [RETRY_STATE_KEY]: { deadlineMilliseconds, nextDelayMilliseconds }
        });
        await createAlarm(deadlineMilliseconds);
      });
    },
    restore() {
      const prepared = serial(async () => {
        const current = await state();
        if (!Number.isFinite(current.deadlineMilliseconds)) {
          await clearAlarm(alarms, RETRY_ALARM_NAME);
          return false;
        }
        if (current.deadlineMilliseconds <= now()) {
          await prepareRetryAfterWake(current);
          return true;
        }
        await ensureAlarm(current.deadlineMilliseconds);
        return false;
      });
      return prepared.then((shouldRetry) => shouldRetry ? retry() : undefined);
    },
    fire(alarm) {
      if (alarm?.name !== RETRY_ALARM_NAME) return Promise.resolve();
      const prepared = serial(async () => {
        const current = await state();
        if (!Number.isFinite(current.deadlineMilliseconds)) {
          await clearAlarm(alarms, RETRY_ALARM_NAME);
          return false;
        }
        await prepareRetryAfterWake(current);
        return true;
      });
      return prepared.then((shouldRetry) => shouldRetry ? retry() : undefined);
    },
    succeed() {
      return serial(async () => {
        await storage.remove(RETRY_STATE_KEY);
        try {
          await clearAlarm(alarms, RETRY_ALARM_NAME);
        } catch {
          // With no retained work, a later restore may remove a stale alarm without retrying.
        }
      });
    }
  };
}

export function createOutboxController(storage, post, scheduleRetry, resetRetry = () => {}) {
  let tail = Promise.resolve();
  const serial = (operation) => {
    const result = tail.then(operation, operation);
    tail = result.catch(() => {});
    return result;
  };

  async function currentState() {
    const current = await storage.get(['sessionId', 'seq', 'outbox']);
    if (current.sessionId) return current;

    const initialized = {
      sessionId: crypto.randomUUID(),
      seq: 0,
      outbox: []
    };
    await storage.set(initialized);
    return initialized;
  }

  return {
    enqueue(frame) {
      return serial(async () => {
        const current = await currentState();
        const outbox = [...(current.outbox ?? []), frame].slice(-OUTBOX_LIMIT);
        await storage.set({ outbox });
      });
    },
    enqueueNewTab(tab) {
      return serial(async () => {
        const current = await currentState();
        const seq = Number(current.seq) + 1;
        const event = toAudibleFrame(tab, current.sessionId, seq);
        const outbox = [...(current.outbox ?? []), event].slice(-OUTBOX_LIMIT);
        await storage.set({ seq, outbox });
        return event;
      });
    },
    acknowledge(ack) {
      return serial(async () => {
        if (ack?.type !== 'ack' || !ack.eventId) return;
        if (ack.disposition === 'retryable_failure') {
          await scheduleRetry();
          return;
        }
        if (!TERMINAL_DISPOSITIONS.has(ack.disposition)) return;

        const current = await currentState();
        const outbox = (current.outbox ?? []).filter((event) => event.eventId !== ack.eventId);
        await storage.set({ outbox });
        if (outbox.length === 0) await resetRetry();
        else await scheduleRetry();
      });
    },
    flush() {
      return serial(async () => {
        const current = await currentState();
        try {
          replayOutbox(current.outbox ?? [], post);
        } catch {
          await scheduleRetry();
        }
      });
    }
  };
}

function retries() {
  if (!retryScheduler) {
    retryScheduler = createRetryScheduler(
      chrome.storage.local,
      chrome.alarms,
      flushOutbox
    );
  }
  return retryScheduler;
}

function scheduleRetry() {
  return retries().schedule();
}

function resetRetryDelay() {
  return retries().succeed();
}

function controller() {
  if (!outboxController) {
    outboxController = createOutboxController(
      chrome.storage.session,
      (event) => connect().postMessage(event),
      scheduleRetry,
      resetRetryDelay
    );
  }
  return outboxController;
}

function connect() {
  if (nativePort) return nativePort;
  const port = chrome.runtime.connectNative(HOST_NAME);
  nativePort = port;
  port.onDisconnect.addListener(() => {
    if (nativePort === port) nativePort = undefined;
    runSafely(scheduleRetry);
  });
  port.onMessage.addListener((message) => {
    runSafely(() => controller().acknowledge(message));
  });
  return port;
}

async function flushOutbox() {
  await controller().flush();
}

async function acknowledge(message) {
  await controller().acknowledge(message);
}

async function sendAudibleTab(tab) {
  await controller().enqueueNewTab(tab);
  await flushOutbox();
}

async function scanAudibleTabs() {
  if (!chrome.tabs?.query) return;
  const tabs = await chrome.tabs.query({ audible: true });
  for (const tab of tabs) await sendAudibleTab(tab);
}

function addListener(owner, eventName, listener) {
  try {
    const target = owner?.[eventName];
    if (target && typeof target.addListener === 'function') {
      target.addListener(listener);
      return true;
    }
    console.warn(`LidMute: ${eventName} unavailable; is the manifest missing a permission?`);
  } catch (error) {
    console.warn(`LidMute: failed to attach ${eventName}`, error);
  }
  return false;
}

if (typeof chrome !== 'undefined') {
  // Register every listener defensively: a missing permission (e.g. an older
  // manifest without "alarms") or unavailable API must never abort service
  // worker evaluation. An uncaught error here surfaces in chrome://extensions
  // as "Service worker registration failed. Status code: 15"
  // (kErrorScriptEvaluateFailed) and disables the whole extension.
  runSafely(connect);
  runSafely(scanAudibleTabs);
  addListener(chrome.tabs, 'onUpdated', (_id, changeInfo, tab) => {
    if (changeInfo.audible === true) runSafely(() => sendAudibleTab(tab));
  });
  addListener(chrome.alarms, 'onAlarm', (alarm) => {
    runSafely(() => retries().fire(alarm));
  });
  runSafely(() => retries().restore());
  addListener(chrome.runtime, 'onStartup', () => {
    runSafely(async () => {
      await retries().restore();
      await flushOutbox();
      await scanAudibleTabs();
    });
  });
  addListener(chrome.runtime, 'onInstalled', () => runSafely(flushOutbox));
}
