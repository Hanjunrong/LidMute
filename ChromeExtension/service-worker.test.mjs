import assert from 'node:assert/strict';
import test from 'node:test';
import { toAudibleFrame } from './service-worker.mjs';

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
