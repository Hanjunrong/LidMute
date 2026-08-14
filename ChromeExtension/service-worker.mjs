const HOST_NAME = 'com.lidmute.nativehost';
const OUTBOX_LIMIT = 256;
const TERMINAL_DISPOSITIONS = new Set([
  'accepted', 'duplicate', 'ignored_incognito', 'rejected_permanent'
]);
let nativePort;
var reconnectTimer;
let retryDelayMilliseconds = 1_000;
let outboxController;

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
          scheduleRetry();
          return;
        }
        if (!TERMINAL_DISPOSITIONS.has(ack.disposition)) return;

        const current = await currentState();
        await storage.set({
          outbox: (current.outbox ?? []).filter((event) => event.eventId !== ack.eventId)
        });
        resetRetry();
      });
    },
    flush() {
      return serial(async () => {
        const current = await currentState();
        try {
          replayOutbox(current.outbox ?? [], post);
        } catch {
          scheduleRetry();
        }
      });
    }
  };
}

function scheduleRetry() {
  if (reconnectTimer) return;

  const delay = retryDelayMilliseconds;
  retryDelayMilliseconds = Math.min(delay * 2, 60_000);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined;
    void flushOutbox();
  }, delay);
}

function resetRetryDelay() {
  retryDelayMilliseconds = 1_000;
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
    scheduleRetry();
  });
  port.onMessage.addListener((message) => void controller().acknowledge(message));
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

if (typeof chrome !== 'undefined') {
  chrome.tabs.onUpdated.addListener((_id, changeInfo, tab) => {
    if (changeInfo.audible === true) void sendAudibleTab(tab);
  });
  chrome.runtime.onStartup.addListener(async () => {
    await flushOutbox();
    for (const tab of await chrome.tabs.query({ audible: true })) void sendAudibleTab(tab);
  });
  chrome.runtime.onInstalled.addListener(() => void flushOutbox());
}
