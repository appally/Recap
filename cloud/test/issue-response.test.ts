import { describe, it, expect } from 'vitest';
import { buildIssueResponse } from '../src/index';

/** /v1/issue 响应形状回归:asr_vocabulary_id 仅在配置全局热词表时携带(新旧客户端双向兼容)。 */
describe('buildIssueResponse', () => {
  const baseEnv = {
    ASR_WSS: 'wss://dashscope.aliyuncs.com/api-ws/v1/inference/',
    LLM_BASE: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    ASR_MODEL: 'paraformer-realtime-v2',
    LLM_MODEL: 'qwen-plus',
  };
  const baseArgs = {
    token: 'sts-test-token',
    tier: 'pro',
    remainingSeconds: 108000,
    signedIn: true,
  };

  it('配置词表 → 响应含 asr_vocabulary_id', () => {
    const body = buildIssueResponse({ ...baseArgs, env: { ...baseEnv, ASR_VOCABULARY_ID: 'vocab-123' } });
    expect(body['asr_vocabulary_id']).toBe('vocab-123');
  });

  it('未配置 → 不带该键(旧客户端形状逐字节不变)', () => {
    const body = buildIssueResponse({ ...baseArgs, env: baseEnv });
    expect(!('asr_vocabulary_id' in body)).toBe(true);
  });

  it('空串 → 同未配置,不带该键', () => {
    const body = buildIssueResponse({ ...baseArgs, env: { ...baseEnv, ASR_VOCABULARY_ID: '' } });
    expect(!('asr_vocabulary_id' in body)).toBe(true);
  });

  it('其余 9 个基础字段不回归', () => {
    const body = buildIssueResponse({ ...baseArgs, env: { ...baseEnv, ASR_VOCABULARY_ID: 'vocab-123' } });
    expect(body).toEqual({
      dashscope_token: 'sts-test-token',
      expires_in: 1800,
      asr_wss: baseEnv.ASR_WSS,
      llm_base: baseEnv.LLM_BASE,
      remaining_seconds: 108000,
      tier: 'pro',
      signed_in: true,
      asr_model: 'paraformer-realtime-v2',
      llm_model: 'qwen-plus',
      asr_vocabulary_id: 'vocab-123',
    });
  });

  it('X-Recap-Lang: en → 下发英文模型(默认 fun-asr-realtime 多语言,与 zh 同白名单)', () => {
    const body = buildIssueResponse({ ...baseArgs, env: baseEnv, lang: 'en' });
    expect(body['asr_model']).toBe('fun-asr-realtime');
  });

  it('lang: en + 配置 ASR_MODEL_EN → 用配置值', () => {
    const body = buildIssueResponse({ ...baseArgs, env: { ...baseEnv, ASR_MODEL_EN: 'custom-en-v2' }, lang: 'en' });
    expect(body['asr_model']).toBe('custom-en-v2');
  });

  it('zh(默认)不受 ASR_MODEL_EN 影响', () => {
    const body = buildIssueResponse({ ...baseArgs, env: { ...baseEnv, ASR_MODEL_EN: 'custom-en-v2' } });
    expect(body['asr_model']).toBe('paraformer-realtime-v2');
  });

  it('lang: en + 配置词表 → 不带 asr_vocabulary_id(词表 target_model 绑 zh 模型,跨模型必 task-failed)', () => {
    const body = buildIssueResponse({
      ...baseArgs,
      env: { ...baseEnv, ASR_VOCABULARY_ID: 'vocab-123' },
      lang: 'en',
    });
    expect(body['asr_model']).toBe('fun-asr-realtime');
    expect(!('asr_vocabulary_id' in body)).toBe(true);
  });

  it('zh 且未配置 ASR_MODEL → 不带 asr_model 键(客户端回落 BYOK 常量)', () => {
    const body = buildIssueResponse({
      ...baseArgs,
      env: { ...baseEnv, ASR_MODEL: undefined as unknown as string },
    });
    expect(!('asr_model' in body)).toBe(true);
  });
});
