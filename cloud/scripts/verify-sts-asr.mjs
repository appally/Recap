#!/usr/bin/env node
/**
 * P0 验证脚本:阿里 DashScope「临时 API Key」能否用于 ASR WebSocket
 *
 * 验证整个「凭证签发器」方案的技术地基。用对照法,排除脚本自身干扰:
 *   A. 主 key (基线)  → Bearer 连 fun-asr-realtime wss,完成 run-task→PCM→finish-task
 *   B. st-临时 token  → 同样流程
 *
 * 判定:
 *   A✅ B✅ → PASS :st-token 可直接 Bearer,方案成立
 *   A✅ B❌ → FAIL :st-token 不能直接 Bearer(打印 B 的错误),wss 鉴权 header 需调整
 *   A❌      → INCONCLUSIVE:主 key 基线就失败(脚本/网络/key 问题),先修这个
 *
 * 用法:
 *   cd cloud && npm install
 *   DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-asr.mjs
 *
 * 安全:主 key 只从环境变量读,本脚本绝不写任何凭证到文件。
 */
import { WebSocket } from 'ws';
import { randomBytes } from 'node:crypto';

const API_KEY = process.env.DASHSCOPE_API_KEY;
const TOKEN_ENDPOINT = 'https://dashscope.aliyuncs.com/api/v1/tokens';
const WS_URL = 'wss://dashscope.aliyuncs.com/api-ws/v1/inference/';
const MODEL = 'fun-asr-realtime';

if (!API_KEY) {
  console.error('✗ 缺少 DASHSCOPE_API_KEY 环境变量。\n  用法: DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-asr.mjs');
  process.exit(1);
}

const newTaskId = () => randomBytes(16).toString('hex'); // 32 hex 小写
const runTask = (id) => ({
  header: { action: 'run-task', task_id: id, streaming: 'duplex' },
  payload: {
    task_group: 'audio', task: 'asr', function: 'recognition', model: MODEL,
    parameters: { format: 'pcm', sample_rate: 16000 }, input: {},
  },
});
const finishTask = (id) => ({
  header: { action: 'finish-task', task_id: id, streaming: 'duplex' },
  payload: { input: {} },
});

async function issueTemporaryToken(expireSeconds = 1800) {
  const res = await fetch(`${TOKEN_ENDPOINT}?expire_in_seconds=${expireSeconds}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${API_KEY}` },
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = { _raw: text }; }
  return { status: res.status, body };
}

/** 跑一次完整 ASR 会话,返回结构化结果。喂 1.5s 静音——验证「鉴权+协议链路」,非验证出字。 */
function runAsrSession(bearerKey, label) {
  return new Promise((resolve) => {
    const taskId = newTaskId();
    const r = { label, connected: false, taskStarted: false, taskFinished: false, failed: null, texts: [] };
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
    const guard = setTimeout(() => finish({ failed: r.failed || '超时(20s)' }), 20000);

    const ws = new WebSocket(WS_URL, {
      headers: { Authorization: `Bearer ${bearerKey}`, 'user-agent': 'recap-verify/1.0' },
    });

    // wss 握手被拒(如 401)时,ws 库触发 unexpected-response 而非 error
    ws.on('unexpected-response', (_req, res) => finish({ failed: `握手被拒 HTTP ${res.statusCode}` }));
    ws.on('error', (e) => finish({ failed: `ws-error: ${e.message}` }));

    ws.on('open', () => {
      r.connected = true;
      ws.send(JSON.stringify(runTask(taskId)));
    });

    ws.on('message', (data) => {
      let obj;
      try { obj = JSON.parse(data.toString()); } catch { return; }
      const event = obj?.header?.event;
      if (event === 'task-started') {
        r.taskStarted = true;
        // 喂 15 包 × 100ms 静音 = 1.5s(1600 samples × 2B = 3200B/包,全 0)
        let i = 0;
        const tick = () => {
          if (i >= 15) {
            try { ws.send(JSON.stringify(finishTask(taskId))); } catch {}
            return;
          }
          if (ws.readyState === WebSocket.OPEN) ws.send(Buffer.alloc(3200));
          i++;
          silenceTimer = setTimeout(tick, 100);
        };
        tick();
      } else if (event === 'result-generated') {
        const s = obj?.payload?.output?.sentence;
        if (s?.text) r.texts.push(s.text);
      } else if (event === 'task-finished') {
        r.taskFinished = true;
        finish();
      } else if (event === 'task-failed') {
        finish({ failed: `task-failed: ${obj?.header?.error_message || obj?.header?.error_code || '未知'}` });
      }
    });

    ws.on('close', (code) => {
      if (!r.taskFinished && !r.failed) finish({ failed: `连接关闭 code=${code}` });
    });
  });
}

function summarize(r) {
  const ok = r.taskStarted && !r.failed;
  console.log(`  [${r.label}] ${ok ? '✅ 通过' : '❌ 失败'}`);
  console.log(`     连接=${r.connected}  task-started=${r.taskStarted}  task-finished=${r.taskFinished}  失败=${r.failed || '无'}`);
  if (r.texts?.length) console.log(`     识别采样(静音可能为空): ${r.texts.join(' / ')}`);
  return ok;
}

console.log('════════════════════════════════════════════════════════════');
console.log(' P0 验证:阿里 st-token 能否 Bearer 直连 ASR wss');
console.log('════════════════════════════════════════════════════════════\n');

console.log('① 签发临时 token (POST /api/v1/tokens) …');
const issued = await issueTemporaryToken(1800);
console.log(`   HTTP ${issued.status}`);
const body = issued.body;
const stToken = body?.token || body?.api_key || body?.data?.token || body?.data?.api_key;
if (!stToken) {
  console.log('   返回体:', JSON.stringify(body));
  console.error('\n✗ 未能从返回体取到临时 token(字段名可能为 token / api_key)。请把上面返回体贴回,我据此修正取值。\n');
  process.exit(1);
}
console.log(`   临时 token: ${stToken.slice(0, 10)}…(已隐藏)\n`);

console.log('② 对照 A:主 key 直连 wss(基线)…');
const A = await runAsrSession(API_KEY, '主 key    (基线)');
const aOk = summarize(A);

console.log('\n③ 对照 B:st-token 直连 wss(目标)…');
const B = await runAsrSession(stToken, 'st-token  (目标)');
const bOk = summarize(B);

console.log('\n──────── 判定 ────────');
if (aOk && bOk) {
  console.log('✅ PASS:st-token 可直接 Bearer 连 ASR wss。「凭证签发器」方案技术地基成立。');
  console.log('   → 推进后端工程骨架与 /v1/issue 实现。');
} else if (aOk && !bOk) {
  console.log('❌ FAIL:st-token 不能直接 Bearer 连 ASR wss。');
  console.log(`   B 失败原因: ${B.failed}`);
  console.log('   → 阿里 wss 对临时 token 可能要求不同 header。方案结构不变,只改客户端 header 一处。');
  console.log('   → 把 B 的失败信息贴回,我据此调整。');
} else {
  console.log('⚠ INCONCLUSIVE:主 key 基线(A)就失败。');
  console.log(`   A 失败原因: ${A.failed}`);
  console.log('   → 先确认:主 key 有效 / 已开通 fun-asr-realtime / 网络可达 wss,再重跑。');
}
console.log('');
