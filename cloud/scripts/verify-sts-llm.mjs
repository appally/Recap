#!/usr/bin/env node
/**
 * LLM 白名单验证脚本:阿里 DashScope 临时 token 能调哪些 qwen 模型
 *
 * 复现/验证「纪要 403 access_denied」根因——主 key 的百炼模型白名单漏开 LLM 模型。
 * 与 verify-sts-asr.mjs 同构:用主 key 换临时 token,再 Bearer 调 OpenAI 兼容 chat 端点。
 *
 * 判定每个候选模型:
 *   200                    → 白名单已放通(app 能用)
 *   403 access_denied      → 模型有效但 key 无权(=白名单漏开,正是 403 根因)
 *   400/404                → 模型名本身无效(不存在/拼错),与白名单无关
 *
 * 用法:
 *   cd cloud
 *   DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-llm.mjs
 *   DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-llm.mjs qwen-plus qwen-flash   # 只测指定模型
 *
 * 安全:主 key 只从环境变量读,本脚本绝不写任何凭证到文件。
 */
const API_KEY = process.env.DASHSCOPE_API_KEY;
const TOKEN_ENDPOINT = 'https://dashscope.aliyuncs.com/api/v1/tokens';
const CHAT_URL = 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';

// 默认探测集:网关当前下发的 qwen-plus + 历史用过的候选名,一次看清白名单全貌。
const DEFAULT_MODELS = ['qwen-plus', 'qwen-flash', 'qwen3.7-flash', 'qwen3.7-plus', 'qwen-turbo'];
// 网关 wrangler.jsonc 的 LLM_MODEL(app 实际请求的模型),用于最终判定。
const APP_MODEL = 'qwen-plus';

if (!API_KEY) {
  console.error('✗ 缺少 DASHSCOPE_API_KEY 环境变量。\n  用法: DASHSCOPE_API_KEY=sk-xxxx node scripts/verify-sts-llm.mjs [model...]');
  process.exit(1);
}

const models = process.argv.slice(2).length ? process.argv.slice(2) : DEFAULT_MODELS;

async function issueTemporaryToken(expireSeconds = 1800) {
  const res = await fetch(`${TOKEN_ENDPOINT}?expire_in_seconds=${expireSeconds}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${API_KEY}` },
  });
  const text = await res.text();
  if (!res.ok) {
    console.error(`✗ 签发临时 token 失败 HTTP ${res.status}: ${text.slice(0, 200)}`);
    process.exit(1);
  }
  let body;
  try { body = JSON.parse(text); } catch { body = { _raw: text }; }
  const token = body?.token || body?.api_key || body?.data?.token || body?.data?.api_key;
  if (!token) {
    console.error(`✗ 未能从返回体取到 token(字段名 token / api_key): ${JSON.stringify(body).slice(0, 200)}`);
    process.exit(1);
  }
  return token;
}

/** 用 token 调一次 chat,max_tokens 限到极小,只为探权限、不真出字。 */
async function probeModel(token, model) {
  const res = await fetch(CHAT_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model,
      messages: [{ role: 'user', content: 'hi' }],
      max_tokens: 1,
      stream: false,
    }),
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = { _raw: text }; }
  const errCode = body?.error?.code || body?.code;
  const errMsg = body?.error?.message || body?.message || text.slice(0, 160);
  return { status: res.status, errCode, errMsg };
}

function verdict(status) {
  if (status === 200) return '✅ 放通';
  if (status === 403) return '❌ 白名单漏开';
  if (status === 400 || status === 404) return '⚠️ 模型名无效';
  return `❓ 未知 HTTP ${status}`;
}

console.log('════════════════════════════════════════════════════════════');
console.log(' LLM 白名单验证:临时 token 能调哪些 qwen 模型');
console.log('════════════════════════════════════════════════════════════\n');

console.log('① 签发临时 token (POST /api/v1/tokens) …');
const token = await issueTemporaryToken(1800);
console.log(`   临时 token: ${token.slice(0, 10)}…(已隐藏)\n`);

console.log('② 逐个探测候选模型 (/compatible-mode/v1/chat/completions) …\n');
const rows = [];
for (const model of models) {
  process.stdout.write(`   • ${model.padEnd(16)} `);
  let r;
  try {
    r = await probeModel(token, model);
  } catch (e) {
    r = { status: -1, errCode: 'network', errMsg: e.message };
  }
  const v = verdict(r.status);
  console.log(`${v}  (HTTP ${r.status}${r.errCode ? ` ${r.errCode}` : ''})`);
  rows.push({ model, ...r, verdict: v });
}

console.log('\n──────── 判定 ────────');
const appRow = rows.find((r) => r.model === APP_MODEL);
if (!appRow) {
  console.log(`ℹ️ 本次未探测 ${APP_MODEL}(app 实际请求的模型);如需判定请带上: node scripts/verify-sts-llm.mjs ${APP_MODEL}`);
} else if (appRow.status === 200) {
  console.log(`✅ app 实际请求的 ${APP_MODEL} 已放通——纪要 403 应已解决,真机重跑确认。`);
} else if (appRow.status === 403) {
  console.log(`❌ app 实际请求的 ${APP_MODEL} 仍 403:百炼控制台 → API-Key 管理 → 编辑该 key →`);
  console.log(`   「模型限制」→ 把 ${APP_MODEL} 加白名单(精确字符串)。改完立即生效,重跑本脚本验证。`);
} else {
  console.log(`⚠️ ${APP_MODEL} 返回 HTTP ${appRow.status}(${appRow.errMsg})——非权限问题,检查模型名/网络。`);
}
console.log('');
