const HOST_NAME = 'com.lidmute.nativehost';
const OUTBOX_LIMIT = 256;
let nativePort;
var reconnectTimer;

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

async function state() {
  const stored = await chrome.storage.session.get(['sessionId', 'seq', 'outbox']);
  if (!stored.sessionId) {
    stored.sessionId = crypto.randomUUID();
    stored.seq = 0;
    stored.outbox = [];
    await chrome.storage.session.set(stored);
  }
  return stored;
}

function connect() {
  if (nativePort) return nativePort;
  nativePort = chrome.runtime.connectNative(HOST_NAME);
  nativePort.onDisconnect.addListener(() => {
    nativePort = undefined;
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => void flushOutbox(), 1_000);
  });
  nativePort.onMessage.addListener(acknowledge);
  return nativePort;
}

async function flushOutbox() {
  const current = await state();
  if (current.outbox.length === 0) return;
  try {
    const port = connect();
    replayOutbox(current.outbox, (event) => port.postMessage(event));
  } catch {
    nativePort = undefined;
  }
}

async function acknowledge(message) {
  if (message?.type !== 'ack') return;
  const current = await state();
  await chrome.storage.session.set({ outbox: current.outbox.filter((event) => event.eventId !== message.eventId) });
}

async function sendAudibleTab(tab) {
  const current = await state();
  const event = toAudibleFrame(tab, current.sessionId, Number(current.seq) + 1);
  const outbox = [...current.outbox, event].slice(-OUTBOX_LIMIT);
  await chrome.storage.session.set({ seq: Number(current.seq) + 1, outbox });
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
