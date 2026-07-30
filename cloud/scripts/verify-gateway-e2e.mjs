#!/usr/bin/env node
/**
 * 端到端验证(客户端真实路径):
 *   Recap 网关(recap.manymind.chat/v1/issue)签发 st-token → 用它直连阿里 ASR wss。
 *
 * 跑通 = 云端托管链路完全成立(后端签发 + 客户端直连 wss),P0 的生产路径版。
 *
 * 用法: node scripts/verify-gateway-e2e.mjs
 * 可选: RECAP_GATEWAY=https://recap.manymind.chat
 */
import { WebSocket } from 'ws';
import { randomBytes } from 'node:crypto';

const GW = process.env.RECAP_GATEWAY ?? 'https://recap.manymind.chat';
const WS_URL = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference/';
const MODEL = 'fun-asr-realtime';

const newTaskId = () => randomBytes(16).toString('hex');
const runTask = (id) => ({
  header: { action: 'run-task', task_id: id, streaming: 'duplex' },
  payload: { task_group: 'audio', task: 'asr', function: 'recognition', model: MODEL, parameters: { format: 'pcm', sample_rate: 16000 }, input: {} },
});
const finishTask = (id) => ({ header: { action: 'finish-task', task_id: id, streaming: 'duplex' }, payload: { input: {} } });

function runAsrSession(bearerKey, label) {
  return new Promise((resolve) => {
    const taskId = newTaskId();
    const r = { label, connected: false, taskStarted: false, taskFinished: false, failed: null, texts: [] };
    let done = false, silenceTimer;
    const finish = (x) => { if (done) return; done = true; if (silenceTimer) clearTimeout(silenceTimer); clearTimeout(guard); try { ws.close(); } catch {} resolve({ ...r, ...x }); };
    const guard = setTimeout(() => finish({ failed: r.failed || '超时(20s)' }), 20000);
    const ws = new WebSocket(WS_URL, { headers: { Authorization: `Bearer ${bearerKey}`, 'user-agent': 'recap-e2e/1.0' } });
    ws.on('unexpected-response', (_q, res) => finish({ failed: `握手被拒 HTTP ${res.statusCode}` }));
    ws.on('error', (e) => finish({ failed: `ws-error: ${e.message}` }));
    ws.on('open', () => { r.connected = true; ws.send(JSON.stringify(runTask(taskId))); });
    ws.on('message', (data) => {
      let o; try { o = JSON.parse(data.toString()); } catch { return; }
      const ev = o?.header?.event;
      if (ev === 'task-started') {
        r.taskStarted = true;
        let i = 0;
        const tick = () => { if (i >= 15) { try { ws.send(JSON.stringify(finishTask(taskId))); } catch {} return; } if (ws.readyState === WebSocket.OPEN) ws.send(Buffer.alloc(3200)); i++; silenceTimer = setTimeout(tick, 100); };
        tick();
      } else if (ev === 'result-generated') { const s = o?.payload?.output?.sentence; if (s?.text) r.texts.push(s.text); }
      else if (ev === 'task-finished') { r.taskFinished = true; finish(); }
      else if (ev === 'task-failed') { finish({ failed: `task-failed: ${o?.header?.error_message || o?.header?.error_code || '?'}` }); }
    });
    ws.on('close', (c) => { if (!r.taskFinished && !r.failed) finish({ failed: `关闭 code=${c}` }); });
  });
}

console.log('═══ Recap 网关 → 阿里 ASR wss 端到端验证 ═══\n');

console.log(`① 从网关 ${GW} 签发 st-token …`);
const res = await fetch(`${GW}/v1/issue`, { method: 'POST', headers: { 'X-Recap-User': 'e2e', 'X-Recap-Pro': '1' } });
const body = await res.json();
if (!body.dashscope_token) { console.error('✗ 签发失败:', JSON.stringify(body)); process.exit(1); }
console.log('   st-token:', body.dashscope_token.slice(0, 14) + '…\n');

console.log('② 用 st-token 直连 ASR wss(模拟客户端)…');
const r = await runAsrSession(body.dashscope_token, 'st-token(via gateway)');
const ok = r.taskStarted && !r.failed;
console.log(`  ${ok ? '✅ 通过' : '❌ 失败'}`);
console.log(`     连接=${r.connected}  task-started=${r.taskStarted}  task-finished=${r.taskFinished}  失败=${r.failed || '无'}`);
if (r.texts?.length) console.log(`     识别采样(静音可能空): ${r.texts.join(' / ')}`);

console.log('\n──────── 判定 ────────');
if (ok) {
  console.log('✅ PASS:网关签发的 st-token 可直接 Bearer 连 ASR wss。云端托管链路完全成立。');
  console.log('   → 客户端 FunASREngine 用此 token 直连,无需任何 header 调整。可推进真机联调。');
} else {
  console.log(`❌ FAIL:st-token 不能 Bearer 连 wss:${r.failed}`);
  console.log('   → 方案结构不变,只改 FunASREngine 一处 header。');
}
