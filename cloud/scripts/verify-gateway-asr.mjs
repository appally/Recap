#!/usr/bin/env node
/**
 * 网关版 ASR 白名单探针:用「网关签发的 token」验百炼 key 对各 ASR 模型的权限。
 *
 * 与 verify-sts-asr.mjs 的区别:那个用「主 key」直连(验主 key 本身);本脚本用「网关 /v1/issue
 * 签发的 st-token」验(=app 实际用的同一条链路),且无需主 key,只打公共网关端点。
 *
 * 用途:wrangler.jsonc 的 ASR_MODEL 已从 fun-asr-realtime 切 paraformer-realtime-v2,但线上 Worker
 * 仍返 fun-asr-realtime(未 deploy)。deploy 前须确认 paraformer 在白名单,否则 ASR st-token 403。
 * 本脚本一次探清 paraformer-realtime-v2 / fun-asr-realtime 的放通状态。
 *
 * 判定:
 *   task-started(喂静音后 finish-task) → ✅ 放通(白名单有)
 *   task-failed / 握手 401 / access_denied      → ❌ 白名单漏开
 *
 * 用法:
 *   cd cloud && node scripts/verify-gateway-asr.mjs
 *   GATEWAY=https://recap.manymind.chat node scripts/verify-gateway-asr.mjs
 */
import { WebSocket } from 'ws';
import { randomBytes } from 'node:crypto';

const GATEWAY = process.env.GATEWAY || 'https://recap.manymind.chat';
const WS_URL = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference/';
const MODELS = ['paraformer-realtime-v2', 'fun-asr-realtime'];

console.log('════════════════════════════════════════════════════════════');
console.log(' 网关 ASR 白名单探针(网关 token → wss run-task)');
console.log('════════════════════════════════════════════════════════════\n');

console.log(`① 打网关 /v1/issue 拿 ASR token (${GATEWAY}) …`);
const devId = `verify-gwasr-${process.pid}`;
const issueRes = await fetch(`${GATEWAY}/v1/issue`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'X-Recap-Usage': 'asr', 'X-Recap-Device': devId },
  body: '{}',
});
if (!issueRes.ok) {
  console.error(`✗ /v1/issue HTTP ${issueRes.status}: ${(await issueRes.text()).slice(0, 200)}`);
  process.exit(1);
}
const issue = await issueRes.json();
const token = issue.dashscope_token;
if (!token) {
  console.error(`✗ 未拿到 token: ${JSON.stringify(issue).slice(0, 200)}`);
  process.exit(1);
}
console.log(`   token: ${token.slice(0, 12)}…  网关下发 asr_model=${issue.asr_model}\n`);

/** 用 token 对指定 model 跑一次 ASR 会话(喂 0.3s 静音),只验鉴权/协议。
 *  vocabularyId 非空时 payload 顶层携带(与 app 的 run-task 同形状,验词表放通)。 */
function probe(model, vocabularyId) {
  return new Promise((resolve) => {
    const taskId = randomBytes(16).toString('hex');
    const r = { model, taskStarted: false, failed: null };
    let done = false;
    let silenceTimer = null;
    const finish = (extra) => {
      if (done) return;
      done = true;
      if (silenceTimer) clearTimeout(silenceTimer);
      clearTimeout(guard);
      try { ws.close(); } catch {}
      resolve({ ...r, ...extra });
    };
    const guard = setTimeout(() => finish({ failed: r.failed || '超时(15s)' }), 15000);

    const ws = new WebSocket(WS_URL, {
      headers: { Authorization: `Bearer ${token}`, 'user-agent': 'recap-gwasr/1.0' },
    });
    ws.on('unexpected-response', (_q, res) => finish({ failed: `握手被拒 HTTP ${res.statusCode}` }));
    ws.on('error', (e) => finish({ failed: `ws-error: ${e.message}` }));
    ws.on('open', () => {
      const payload = { task_group: 'audio', task: 'asr', function: 'recognition', model, parameters: { format: 'pcm', sample_rate: 16000 }, input: {} };
      if (vocabularyId) payload.vocabulary_id = vocabularyId;
      ws.send(JSON.stringify({
        header: { action: 'run-task', task_id: taskId, streaming: 'duplex' },
        payload,
      }));
    });
    ws.on('message', (data) => {
      let obj;
      try { obj = JSON.parse(data.toString()); } catch { return; }
      const ev = obj?.header?.event;
      if (ev === 'task-started') {
        r.taskStarted = true;
        let i = 0;
        const tick = () => {
          if (i >= 3) {
            try { ws.send(JSON.stringify({ header: { action: 'finish-task', task_id: taskId, streaming: 'duplex' }, payload: { input: {} } })); } catch {}
            return;
          }
          if (ws.readyState === WebSocket.OPEN) ws.send(Buffer.alloc(3200));
          i++;
          silenceTimer = setTimeout(tick, 100);
        };
        tick();
      } else if (ev === 'task-failed') {
        finish({ failed: `task-failed: ${obj?.header?.error_code || obj?.header?.error_message || '未知'}` });
      } else if (ev === 'task-finished') {
        finish();
      }
    });
  });
}

console.log('② 逐个探测 ASR 模型(api-ws run-task) …\n');
for (const m of MODELS) {
  const r = await probe(m);
  const ok = r.taskStarted && !r.failed;
  console.log(`   • ${m.padEnd(24)} ${ok ? '✅ 放通' : '❌ ' + (r.failed || '未启动')}`);
}

console.log('\n②.5 热词词表探针(payload.vocabulary_id) …');
if (issue.asr_vocabulary_id) {
  const r = await probe(issue.asr_model || 'paraformer-realtime-v2', issue.asr_vocabulary_id);
  const ok = r.taskStarted && !r.failed;
  console.log(`   • ${String(issue.asr_model).padEnd(24)} + vocab ${issue.asr_vocabulary_id}  ${ok ? '✅ 词表放通' : '❌ ' + (r.failed || '未启动')}`);
} else {
  console.log('   • issue 响应未带 asr_vocabulary_id(ASR_VOCABULARY_ID 未配置或为空)——托管档热词未启用,跳过');
}

console.log('\n③ 负向探针:同一 ASR token 调 LLM chat 接口应被拒 …');
const llmProbe = await fetch(
  'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
  {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'qwen-plus', messages: [{ role: 'user', content: 'hi' }], max_tokens: 4 }),
  },
);
const llmStatus = llmProbe.status;
console.log(`   • ASR token → qwen-plus chat: HTTP ${llmStatus} ${
  llmStatus === 403 ? '✅ 已隔离(越权被拒)' : llmStatus === 401 ? '✅ 已隔离(401)' : '❌ 竟放通!白名单/双子账号未生效'
}`);

console.log('\n──────── 判定 ────────');
console.log('若 paraformer-realtime-v2 标 ❌:百炼控制台给该 key 的白名单加 paraformer-realtime-v2,');
console.log('   再 deploy wrangler.jsonc(ASR_MODEL 已切 paraformer)。否则 deploy 后 ASR 会 st-token 403。');
console.log('英文托管会议(ASR_MODEL_EN)与 zh 同走 fun-asr-realtime(多语言自动检测)——');
console.log('   百炼无英文专用实时模型(paraformer-realtime-en-v1 不存在,2026-08-23 双确认),');
console.log('   故 fun-asr-realtime ✅ 即英文链路放通;若未来切 qwen-audio 等英文模型,先加白名单+本探针。');
console.log('若 ✅:可安全 deploy 切 paraformer(¥0.864/h,比 fun-asr 省 27% + 18 方言)。');
console.log('负向探针若 ❌(放通):立即在百炼控制台收紧该 key 模型白名单,或配置 DASHSCOPE_ASR_API_KEY');
console.log('   双子账号隔离(见 wrangler.jsonc Secrets 注释),否则免费用户可持 ASR 桶 token 刷 LLM。');
console.log('热词词表若 ❌(task-failed 含 vocabulary/invalid):词表 target_model 与 ASR_MODEL 不一致——');
console.log('   在百炼控制台改绑/重建词表后再 deploy。客户端有清词重试兜底,但热词会静默失效。');
console.log('');
