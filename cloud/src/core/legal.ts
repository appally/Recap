/** 纪要 官网 —— 响应 4 项精准反馈重构版
 *  1. 彻底清除 "Recap" 英文字样，全局统一使用「纪要」
 *  2. 移除顶部导航栏
 *  3. 替换主标题为打动用户的痛点标语：“开会只管思考，纪要自动归案。”
 *  4. 彻底移除“平静美学”，聚焦实用的多模态、20+ 模板、闭环待办与 AI 调研
 */

import { ICON_DATA_URL } from './icon';

const STYLE = `
:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --paper: #ffffff;
  --paper-subtle: #f9fafb;
  --ink: #111827;
  --ink-secondary: #4b5563;
  --ink-tertiary: #9ca3af;
  --hairline: rgba(0, 0, 0, 0.08);
  --hairline-strong: rgba(0, 0, 0, 0.16);
  --shadow-subtle: 0 1px 3px rgba(0,0,0,0.04), 0 12px 24px -6px rgba(0,0,0,0.04);
  --shadow-device: 0 32px 64px -16px rgba(0, 0, 0, 0.14), 0 0 0 1px rgba(0, 0, 0, 0.06);
  --radius-lg: 16px;
  --radius-md: 10px;
  --font-serif: "Songti SC", "Noto Serif CJK SC", "Source Han Serif SC", "STSong", Georgia, serif;
  --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "PingFang SC", "Helvetica Neue", sans-serif;
  --font-mono: "SF Mono", Menlo, Monaco, Consolas, monospace;
  /* 动效令牌 —— 自定义曲线取代默认 ease，落点更有意图感 */
  --ease-out: cubic-bezier(0.22, 1, 0.36, 1);
  --ease-standard: cubic-bezier(0.4, 0, 0.2, 1);
  --dur-press: 140ms;
  --dur-fast: 180ms;
  --dur-base: 220ms;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0c0d10;
    --paper: #13151a;
    --paper-subtle: #191c24;
    --ink: #f3f4f6;
    --ink-secondary: #9ca3af;
    --ink-tertiary: #4b5563;
    --hairline: rgba(255, 255, 255, 0.08);
    --hairline-strong: rgba(255, 255, 255, 0.18);
    --shadow-subtle: 0 16px 32px rgba(0,0,0,0.4);
    --shadow-device: 0 32px 80px rgba(0,0,0,0.7), 0 0 0 1px rgba(255,255,255,0.1);
  }
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  /* 保留颜色/透明度过渡(辅助理解)，仅移除位移与缩放类动效 */
  .hero > * { animation: none !important; opacity: 1 !important; transform: none !important; }
}
body {
  font-family: var(--font-sans);
  background: var(--bg);
  color: var(--ink);
  margin: 0;
  line-height: 1.75;
  font-size: 16px;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

a { color: var(--ink); text-decoration: underline; text-underline-offset: 3px; text-decoration-color: var(--hairline-strong); transition: color var(--dur-fast) var(--ease-out), text-decoration-color var(--dur-fast) var(--ease-out); }
a:hover { text-decoration-color: var(--ink); }

.wrap { max-width: 860px; margin: 0 auto; padding: 0 28px; }

/* 品牌顶标 (替代原导航栏) */
.brand-bar {
  padding: 32px 0 0;
  display: flex;
  justify-content: center;
}
.brand-mark {
  display: flex;
  align-items: center;
  gap: 10px;
  text-decoration: none;
  font-weight: 700;
  font-size: 19px;
  color: var(--ink);
  letter-spacing: -0.01em;
  transition: opacity var(--dur-fast) var(--ease-out);
}
.brand-mark:active { opacity: 0.55; }
.brand-mark img {
  width: 32px;
  height: 32px;
  border-radius: 8px;
}

/* Hero 区域 */
.hero {
  padding: 44px 0 44px;
  text-align: center;
}

.hero-tag {
  display: inline-block;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--ink-tertiary);
  margin-bottom: 18px;
}

.hero h1 {
  font-family: var(--font-serif);
  font-size: clamp(38px, 6.5vw, 56px);
  font-weight: 600;
  letter-spacing: -0.02em;
  margin: 0 0 18px;
  line-height: 1.25;
  color: var(--ink);
}

.hero .sub {
  font-size: clamp(16px, 2.2vw, 18px);
  color: var(--ink-secondary);
  max-width: 640px;
  margin: 0 auto 36px;
  font-weight: 400;
  line-height: 1.75;
}

/* Hero 进场 —— 仅一次、克制的错峰淡入(首屏稀有视图允许的 delight) */
.hero > * {
  opacity: 0;
  transform: translateY(10px);
  animation: heroIn 620ms var(--ease-out) forwards;
}
.hero > *:nth-child(1) { animation-delay: 40ms; }
.hero > *:nth-child(2) { animation-delay: 120ms; }
.hero > *:nth-child(3) { animation-delay: 200ms; }
.hero > *:nth-child(4) { animation-delay: 280ms; }
@keyframes heroIn {
  to { opacity: 1; transform: none; }
}

.cta-group {
  display: flex;
  gap: 16px;
  align-items: center;
  justify-content: center;
}

.cta-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  background: var(--ink);
  color: var(--bg);
  padding: 13px 30px;
  border-radius: 999px;
  font-weight: 500;
  font-size: 15px;
  text-decoration: none;
  transition: transform var(--dur-press) var(--ease-out), opacity var(--dur-base) var(--ease-out);
}
.cta-btn:active { transform: scale(0.97); }
.cta-btn--block { width: 100%; }
@media (hover: hover) and (pointer: fine) {
  .cta-btn:hover { opacity: 0.9; text-decoration: none; }
}

.apple-icon { width: 16px; height: 16px; fill: currentColor; }

/* iPhone 多模态 Markdown 展示框 */
.showcase-section {
  margin: 44px 0 84px;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.showcase-caption {
  font-family: var(--font-mono);
  font-size: 11.5px;
  color: var(--ink-tertiary);
  margin-bottom: 20px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.iphone-frame {
  width: 100%;
  max-width: 348px;
  background: var(--paper);
  border-radius: 44px;
  box-shadow: var(--shadow-device);
  padding: 11px;
  border: 1px solid var(--hairline);
}

.iphone-screen {
  background: var(--paper);
  border-radius: 34px;
  overflow: hidden;
  border: 1px solid var(--hairline);
  display: flex;
  flex-direction: column;
  text-align: left;
  position: relative;
}

/* Dynamic Island —— 现代 iPhone 标志性视觉锚点，取代扁平顶框的"过时感" */
.dynamic-island {
  position: absolute;
  top: 10px;
  left: 50%;
  transform: translateX(-50%);
  width: 78px;
  height: 22px;
  background: #000;
  border-radius: 999px;
  z-index: 2;
}
@media (prefers-color-scheme: dark) {
  .dynamic-island { box-shadow: 0 0 0 0.5px rgba(255, 255, 255, 0.14); }
}

.iphone-status {
  padding: 12px 20px 4px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 11px;
  font-weight: 600;
  color: var(--ink-secondary);
}
.status-cluster { display: inline-flex; align-items: center; gap: 5px; }
.status-cluster svg { display: block; }

.iphone-editor {
  padding: 20px;
  font-size: 13.5px;
  line-height: 1.7;
}

.editor-tag {
  font-family: var(--font-mono);
  font-size: 11px;
  color: var(--ink-tertiary);
  margin-bottom: 8px;
}

.editor-title {
  font-family: var(--font-serif);
  font-size: 18px;
  font-weight: 600;
  color: var(--ink);
  margin: 0 0 14px;
  padding-bottom: 10px;
  border-bottom: 1px solid var(--hairline);
}

.editor-meta {
  font-family: var(--font-mono);
  font-size: 11px;
  color: var(--ink-tertiary);
  margin-bottom: 4px;
}

.editor-p {
  color: var(--ink-secondary);
  margin-bottom: 12px;
}

/* 多模态图片与手写卡片 */
.editor-multimodal-card {
  background: var(--paper-subtle);
  border: 1px dashed var(--hairline-strong);
  border-radius: 8px;
  padding: 8px 12px;
  margin: 12px 0;
  font-size: 12px;
  color: var(--ink-secondary);
  display: flex;
  align-items: center;
  gap: 8px;
}

.editor-quote {
  background: var(--paper-subtle);
  border-left: 2.5px solid var(--ink);
  padding: 10px 14px;
  border-radius: 0 8px 8px 0;
  margin: 14px 0;
  font-size: 13px;
}

.editor-quote-title {
  font-weight: 600;
  color: var(--ink);
  margin-bottom: 4px;
}
.editor-quote-body {
  color: var(--ink-secondary);
  font-size: 12.5px;
  line-height: 1.7;
}

.editor-todo {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--ink-secondary);
  margin-top: 8px;
  background: var(--paper-subtle);
  padding: 8px 10px;
  border-radius: 6px;
}

.editor-checkbox {
  width: 13px;
  height: 13px;
  border: 1.5px solid var(--ink);
  background: var(--ink);
  border-radius: 3px;
  flex-shrink: 0;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.editor-checkbox::after {
  content: "✓";
  color: var(--bg);
  font-size: 9px;
  font-weight: 700;
  line-height: 1;
}

/* 核心功能 6 大支柱 (Features Grid) */
.section-block {
  border-top: 1px solid var(--hairline);
  padding: 72px 0;
}

.section-num {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--ink-tertiary);
  margin-bottom: 8px;
  display: block;
}
.section-title {
  font-family: var(--font-serif);
  font-size: 28px;
  font-weight: 600;
  margin: 0 0 44px;
  letter-spacing: -0.01em;
}

.feature-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 44px 36px;
}
@media (max-width: 640px) {
  .feature-grid { grid-template-columns: 1fr; gap: 36px; }
}

.feature-item {
  display: flex;
  flex-direction: column;
}

.feature-code {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--ink-tertiary);
  margin-bottom: 10px;
}

.feature-item h3 {
  font-size: 17px;
  font-weight: 600;
  margin: 0 0 8px;
  color: var(--ink);
}

.feature-item p {
  font-size: 14.5px;
  color: var(--ink-secondary);
  margin: 0;
  line-height: 1.7;
}

/* 适用场景 4 大工作流 */
.scenario-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 20px;
}
@media (max-width: 640px) {
  .scenario-grid { grid-template-columns: 1fr; }
}

.scenario-card {
  background: var(--paper-subtle);
  border: 1px solid var(--hairline);
  border-radius: var(--radius-lg);
  padding: 24px;
}
.scenario-card h4 {
  font-size: 16px;
  font-weight: 600;
  margin: 0 0 6px;
  color: var(--ink);
}
.scenario-card p {
  font-size: 14px;
  color: var(--ink-secondary);
  margin: 0;
  line-height: 1.65;
}

/* 订阅方案 —— 双卡对比 */
.pricing-section {
  border-top: 1px solid var(--hairline);
  padding: 72px 0 96px;
}
.pricing-head { text-align: center; margin-bottom: 44px; }
.pricing-head .section-num { display: block; }
.pricing-head .section-title { margin: 0 0 14px; }
.pricing-lead {
  font-size: 15px;
  color: var(--ink-secondary);
  max-width: 560px;
  margin: 0 auto;
  line-height: 1.7;
}

.price-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 20px;
  align-items: stretch;
  max-width: 720px;
  margin: 0 auto;
}
@media (max-width: 640px) {
  .price-grid { grid-template-columns: 1fr; }
}

.price-card {
  position: relative;
  background: var(--paper);
  border: 1px solid var(--hairline);
  border-radius: var(--radius-lg);
  padding: 32px 28px;
  display: flex;
  flex-direction: column;
  text-align: left;
}
.price-card--featured {
  border-color: var(--ink);
  box-shadow: var(--shadow-subtle);
}
.price-card .cta-btn { margin-top: auto; }

.price-badge {
  position: absolute;
  top: 16px;
  right: 16px;
  font-family: var(--font-mono);
  font-size: 10.5px;
  font-weight: 600;
  letter-spacing: 0.06em;
  padding: 4px 9px;
  border-radius: 999px;
  background: var(--ink);
  color: var(--bg);
}
.price-badge--ghost {
  background: var(--paper-subtle);
  color: var(--ink-secondary);
}

/* 次级按钮 —— BYOK 卡用描边样式，与主订阅 CTA 视觉分级 */
.cta-btn--ghost {
  background: transparent;
  color: var(--ink);
  border: 1px solid var(--hairline-strong);
}
@media (hover: hover) and (pointer: fine) {
  .cta-btn--ghost:hover { background: var(--paper-subtle); opacity: 1; }
}

.pricing-foot {
  text-align: center;
  font-size: 13px;
  color: var(--ink-tertiary);
  max-width: 600px;
  margin: 36px auto 0;
  line-height: 1.7;
}

.price-title {
  font-family: var(--font-serif);
  font-size: 22px;
  font-weight: 600;
  margin: 0 0 12px;
}

.price-val {
  font-size: 32px;
  font-weight: 700;
  color: var(--ink);
  margin-bottom: 4px;
}
.price-period {
  font-size: 16px;
  font-weight: 400;
  color: var(--ink-tertiary);
}
.price-sub {
  font-size: 13px;
  color: var(--ink-tertiary);
  margin-bottom: 24px;
}

.price-items {
  text-align: left;
  margin-bottom: 32px;
}
.price-item {
  font-size: 14px;
  color: var(--ink-secondary);
  margin: 10px 0;
  display: flex;
  align-items: center;
  gap: 10px;
}
.price-dot {
  width: 4px;
  height: 4px;
  border-radius: 50%;
  background: var(--ink);
}

/* 文档排版 (隐私政策 / 条款) */
.doc { padding: 60px 0 96px; }
.doc h1 { font-family: var(--font-serif); font-size: 32px; font-weight: 600; margin: 0 0 8px; }
.doc .meta { font-family: var(--font-mono); color: var(--ink-tertiary); font-size: 12.5px; margin-bottom: 36px; padding-bottom: 16px; border-bottom: 1px solid var(--hairline); }
.doc h2 { font-size: 18px; font-weight: 600; margin: 36px 0 12px; color: var(--ink); }
.doc p, .doc li { font-size: 15px; color: var(--ink-secondary); line-height: 1.8; }
.doc ul { padding-left: 20px; }
.doc li { margin: 6px 0; }

/* 页脚 Footer */
footer {
  border-top: 1px solid var(--hairline);
  padding: 40px 0;
  font-size: 13px;
  color: var(--ink-tertiary);
  text-align: center;
}
.footer-links { margin-bottom: 12px; }
.footer-links a { color: var(--ink-secondary); margin: 0 12px; text-decoration: none; transition: color var(--dur-fast) var(--ease-out); }
.footer-links a:active { opacity: 0.5; }
@media (hover: hover) and (pointer: fine) {
  .footer-links a:hover { color: var(--ink); text-decoration: underline; }
}
`;

const APPLE_SVG = `<svg class="apple-icon" viewBox="0 0 170 170" fill="currentColor"><path d="M150.37 130.25c-2.45 5.66-5.35 10.87-8.71 15.66-4.58 6.53-8.33 11.05-11.22 13.56-4.48 4.12-9.28 6.23-14.42 6.35-3.69 0-8.14-1.05-13.32-3.18-5.19-2.12-9.97-3.17-14.34-3.17-4.58 0-9.49 1.05-14.75 3.17-5.26 2.13-9.5 3.24-12.74 3.35-5.03.23-9.94-1.8-14.73-6.08-3.3-2.91-7.18-7.6-11.64-14.07-6.53-9.5-11.63-19.98-15.3-31.42-3.67-11.45-5.5-22.42-5.5-32.92 0-12.69 3.01-23.47 9.03-32.35 6.02-8.88 13.82-13.43 23.4-13.65 4.81 0 10.02 1.25 15.63 3.75 5.61 2.5 9.77 3.86 12.49 4.09 2.57 0 6.89-1.4 12.96-4.19 6.07-2.79 11.44-4.04 16.12-3.75 9.87.65 17.65 4.3 23.34 10.95-10.45 6.31-15.54 15.22-15.27 26.74.27 9.04 3.7 16.59 10.3 22.65 6.6 6.06 14.4 9.48 23.4 10.26-2.58 7.74-6.17 15.37-10.77 22.9zM119.22 31.74c0-6.1 2.22-11.96 6.66-17.58 4.44-5.62 10.08-9.42 16.92-11.41.6 3.65.26 7.42-1.02 11.31-1.28 3.89-3.41 7.45-6.39 10.68-3.07 3.32-6.66 5.86-10.77 7.62-4.11 1.76-7.89 2.45-11.34 2.07.13-9.59 2.11-13.6 5.94-2.69z"/></svg>`;

/** iOS 状态栏右侧 —— 信号 / Wi-Fi / 电量，取代伪文本，提升真实感 */
const STATUS_SVG = `<svg width="18" height="10" viewBox="0 0 18 10" fill="currentColor" aria-hidden="true"><rect x="0" y="6" width="3" height="4" rx=".75"/><rect x="5" y="4" width="3" height="6" rx=".75"/><rect x="10" y="2" width="3" height="8" rx=".75"/><rect x="15" y="0" width="3" height="10" rx=".75"/></svg><svg width="15" height="11" viewBox="0 0 16 12" fill="currentColor" aria-hidden="true"><path d="M8 1.2C5 1.2 2.3 2.4.4 4.3L1.7 5.6C3.2 4 5.5 3 8 3s4.8 1 6.3 2.6l1.3-1.3C13.7 2.4 11 1.2 8 1.2z"/><path d="M8 4.8c-2 0-3.8.8-5.1 2.1l1.3 1.3C5.2 7.2 6.5 6.6 8 6.6s2.8.6 3.8 1.6l1.3-1.3C11.8 5.6 10 4.8 8 4.8z"/><circle cx="8" cy="10" r="1.7"/></svg><svg width="25" height="12" viewBox="0 0 25 12" aria-hidden="true"><rect x=".5" y=".5" width="21" height="11" rx="3.2" fill="none" stroke="currentColor" stroke-opacity=".35"/><rect x="2" y="2" width="18" height="8" rx="1.8" fill="currentColor"/><path d="M23 3.8v4.4c1 .3 1-1.4 1-2.2s0-2.5-1-2.2z" fill="currentColor" fill-opacity=".35"/></svg>`;

function page(title: string, body: string, isDoc = false): string {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<link rel="icon" type="image/png" href="${ICON_DATA_URL}">
<meta name="description" content="纪要 —— 开会只管思考，纪要自动归案。iOS 智能语音会议纪要与行动助手。">
<style>${STYLE}</style></head><body>
<main class="${isDoc ? 'doc' : ''}"><div class="wrap">
  <div class="brand-bar">
    <a class="brand-mark" href="/">
      <img src="${ICON_DATA_URL}" alt="纪要 App Icon">
      <span>纪要</span>
    </a>
  </div>
  ${body}
</div></main>
<footer><div class="wrap">
  <div class="footer-links">
    <a href="/privacy">隐私政策</a>·<a href="/terms">使用条款</a>·<a href="/support">支持与帮助</a>
  </div>
  <div>© 2026 纪要 · support@manymind.chat</div>
</div></footer>
</body></html>`;
}

export function landingHTML(): string {
  return page('纪要 · 开会只管思考，纪要自动归案', `
<!-- Hero 极简区域 -->
<div class="hero">
  <span class="hero-tag">iOS 18 NATIVE · APPLE INTELLIGENCE</span>
  <h1>开会只管思考，纪要自动归案。</h1>
  <p class="sub">把漫长冗长的会议讨论，瞬间澄清为清晰的决议大纲与可执行待办。<br>板书拍照与 Apple Pencil 笔记无缝融入，让每一场讨论都真正落地。</p>
  <div class="cta-group">
    <a class="cta-btn" href="#">${APPLE_SVG} <span>在 App Store 下载</span></a>
  </div>
</div>

<!-- iPhone 多模态 Markdown 阅读界面 Showcase -->
<div class="showcase-section">
  <div class="showcase-caption">MULTIMODAL NOTEBOOK & ACTIONABLE DECISIONS</div>
  <div class="iphone-frame">
    <div class="iphone-screen">
      <div class="dynamic-island"></div>
      <div class="iphone-status">
        <span>9:41</span>
        <span class="status-cluster">${STATUS_SVG}</span>
      </div>
      <div class="iphone-editor">
        <div class="editor-tag">周会·产品与架构评审</div>
        <div class="editor-title">Phase 2 架构重构与端侧隐私规约</div>
        
        <div class="editor-meta">SPEAKER 01 (张立) · 10:14</div>
        <div class="editor-p">本次 Phase 2 的核心是将通信完全收敛为设备直连，消灭中转留存。</div>

        <!-- 现场 PPT 拍照融合 -->
        <div class="editor-multimodal-card">
          📷 <span><b>现场 PPT 拍照</b>: Phase_2_Architecture.png (已自动解析图表与文字)</span>
        </div>

        <!-- Apple Pencil 手写批注融合 -->
        <div class="editor-multimodal-card">
          ✏️ <span><b>Apple Pencil 涂鸦速记</b>: "确认跨端协议兼容性" (已识别融入)</span>
        </div>

        <div class="editor-quote">
          <div class="editor-quote-title">✦ 核心决议要点</div>
          <div class="editor-quote-body">1. 确定上线端侧 ASR 离线转写双引擎。<br>2. 会前议程自动对比完成度。</div>
        </div>

        <div class="editor-todo">
          <div class="editor-checkbox"></div>
          <span>@张立：确认 Apple Intelligence 兼容性测试 (已静默同步至系统提醒事项)</span>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- 6 大核心功能支柱 -->
<section id="features" class="section-block">
  <span class="section-num">01 / CAPABILITIES</span>
  <h2 class="section-title">让每一次讨论都高效落地</h2>

  <div class="feature-grid">
    <div class="feature-item">
      <div class="feature-code">01 / HIGH PRECISION TRANSCRIPTION</div>
      <h3>高精录音转写，声音清晰留存</h3>
      <p>支持普通话与方言识别，离线或断网环境下顺畅记录。自动修正错别字并去除冗余口头禅；已录音频采用断点落盘保护，异常退出后尽可能保留已录内容。</p>
    </div>

    <div class="feature-item">
      <div class="feature-code">02 / 20+ SCENARIO TEMPLATES</div>
      <h3>20+ 种场景模板，即刻成文</h3>
      <p>自动生成摘要与核心决议。内置周报生成、销售复盘、客户拜访、1on1 面谈、面试评估、Cornell 学习笔记、思维导图大纲等模板，亦可轻松定制专属模板。</p>
    </div>

    <div class="feature-item">
      <div class="feature-code">03 / MULTIMODAL INTEGRATION</div>
      <h3>多模态结合，拍照与手写自动融入</h3>
      <p>现场拍摄的演示 PPT、板书或资料照片，自动按时间锚定并解析文字，无缝织进纪要中；支持 Apple Pencil 涂鸦速记识别融入。</p>
    </div>

    <div class="feature-item">
      <div class="feature-code">04 / CLOSED-LOOP EXECUTION</div>
      <h3>闭环执行，待办真正落地</h3>
      <p>准确识别谁在什么时间完成什么任务。确认后的待办可一键静默同步至系统提醒事项；支持会前底稿对账与完成度对比。</p>
    </div>

    <div class="feature-item">
      <div class="feature-code">05 / AI ASSISTANT & RESEARCH</div>
      <h3>问纪要 AI 助手与深度调研</h3>
      <p>会中会后随时提问，快速查找原文引文与细节结论。针对复杂待办事项可发起 AI 深度调研，自动检索分析网页资料并撰写报告草稿。</p>
    </div>

    <div class="feature-item">
      <div class="feature-code">06 / FREE LLM CHOICE & PRIVACY</div>
      <h3>自由模型接入，端侧隐私保障</h3>
      <p>内置免费基础处理能力，亦支持自由绑定 DeepSeek、通义千问、豆包、Kimi、智谱、OpenAI 等大模型。核心数据完全存储在手机本地。</p>
    </div>
  </div>
</section>

<!-- 4 大真实工作流 -->
<section id="scenarios" class="section-block">
  <span class="section-num">02 / USE CASES</span>
  <h2 class="section-title">全场景覆盖与流转</h2>

  <div class="scenario-grid">
    <div class="scenario-card">
      <h4>👥 团队例会与产品评审</h4>
      <p>实时生成要点与待办，权责明确，会后一键同步至系统提醒事项。</p>
    </div>

    <div class="scenario-card">
      <h4>🤝 商务洽谈与客户拜访</h4>
      <p>专注对话交流，无需分心打字，精准捕捉客户需求与跟进细节。</p>
    </div>

    <div class="scenario-card">
      <h4>🎓 学术讲座与培训研讨</h4>
      <p>长语音高精转写，结合 Cornell 笔记模板与思维导图快速检索重点。</p>
    </div>

    <div class="scenario-card">
      <h4>💡 个人灵感与随手记事</h4>
      <p>行走或行车途中的口述灵感，一键整理成结构化文档。</p>
    </div>
  </div>
</section>

<!-- 订阅方案 —— 双卡对比 -->
<section id="pricing" class="pricing-section">
  <div class="pricing-head">
    <span class="section-num">03 / PRICING</span>
    <h2 class="section-title">两种付费方式，按需选择</h2>
    <p class="pricing-lead">不想折腾？选订阅，开箱即用。有自己的模型？一次买断，永无续费。下载即享免费基础功能。</p>
  </div>

  <div class="price-grid">
    <div class="price-card price-card--featured">
      <span class="price-badge">推荐</span>
      <div class="price-title">纪要 Pro · 订阅</div>
      <div class="price-val">¥198 <span class="price-period">/ 年</span></div>
      <div class="price-sub">或 ¥25 / 月 · 免配置 · 随时取消</div>

      <div class="price-items">
        <div class="price-item"><span class="price-dot"></span> 免配置 API Key，云端能力开箱即用</div>
        <div class="price-item"><span class="price-dot"></span> 大容量云端转写（合理使用配额）与多发言人精细区分</div>
        <div class="price-item"><span class="price-dot"></span> 20+ 场景模板与问纪要 AI 深度调研</div>
        <div class="price-item"><span class="price-dot"></span> 订阅费代付云端成本，数据仍存本地</div>
      </div>

      <a class="cta-btn cta-btn--block" href="#">在 App Store 下载</a>
    </div>

    <div class="price-card">
      <span class="price-badge price-badge--ghost">买断</span>
      <div class="price-title">自带模型 · 买断</div>
      <div class="price-val">¥68 <span class="price-period">一次买断</span></div>
      <div class="price-sub">绑定你自己的 API Key · 永无续费</div>

      <div class="price-items">
        <div class="price-item"><span class="price-dot"></span> 一次付费解锁全部纪要与多模态能力</div>
        <div class="price-item"><span class="price-dot"></span> 自由接入 DeepSeek / 通义 / 豆包 / Kimi / 智谱 / OpenAI</div>
        <div class="price-item"><span class="price-dot"></span> 转写与 AI 调用费用走你自己的厂商账号</div>
        <div class="price-item"><span class="price-dot"></span> 核心数据完全存储在本机</div>
      </div>

      <a class="cta-btn cta-btn--block cta-btn--ghost" href="#">在 App Store 下载</a>
    </div>
  </div>

  <p class="pricing-foot">免费档同样可用：基础转写、纪要与每月 AI 额度。两档付费均通过 Apple App Store 结算，可随时在 iOS 系统设置中管理或取消。</p>
</section>`);
}

export function privacyHTML(): string {
  return page('隐私政策 · 纪要', `
<h1>隐私政策</h1>
<p class="meta">生效日期: 2026-08-15 · 纪要</p>
<h2>概述</h2>
<p><strong>纪要</strong> 是一款专为 iOS/iPadOS 打造的效率工具，采用<strong>本地优先 (Local-First)</strong> 设计理念：你的录音音频、转写文本、结构化纪要与手写笔记<strong>默认仅保存在你的设备上</strong>。我们不运营存储你会议内容的中央服务器。</p>
<h2>处理的数据</h2>
<ul>
  <li><strong>录音与会议内容</strong>：音频在本地磁盘落盘，转写、纪要均存储于本机数据库。除非你主动导出或启用云端能力，内容绝不会离开设备。</li>
  <li><strong>账户与身份（可选）</strong>：你可以选择「通过 Apple 登录」或完全本地匿名使用。选择登录时，我们仅保留 Apple 返回的无标识 User ID 与昵称，用于签发云端服务凭证与统计月度用量。你可以在应用内「账户」页面随时删除账户，删除后服务端账户标识与用量记录将被清除，本机已保存的声纹特征也会一并移除；本机会议内容可在应用内「数据与隐私」中另行清除。</li>
  <li><strong>订阅状态</strong>：纪要 Pro 通过 Apple App Store 完成购买，支付过程完全由 Apple 托管。</li>
</ul>
<h2>声纹说话人识别（生物识别信息）</h2>
<p>「区分不同发言人」功能会在<strong>本机</strong>从录音中提取说话人声纹特征（不可还原为原始语音的数值向量），用于给同一说话人在本场及跨场会议中匹配身份。<strong>声纹特征属于生物识别信息，属于敏感个人信息</strong>：</p>
<ul>
  <li>声纹特征的提取、比对与存储<strong>全部在你的设备上完成</strong>，不会上传到任何服务器。</li>
  <li>首次启用时，应用会向你展示单独同意页面；你可以选择拒绝，拒绝后不会在本机保存声纹特征，单场会议内的说话人分离仍可使用，跨会议的说话人身份识别不可用，录音、转写与纪要功能不受影响。</li>
  <li>你可以随时在应用的说话人设置中删除已保存的声纹特征；删除账户或清除会议数据也会一并移除。</li>
</ul>
<h2>云端转写与 AI 纪要</h2>
<ul>
  <li><strong>自备 API 密钥模式</strong>：配置厂商 API Key（如 DeepSeek、通义千问、Kimi、OpenAI）时，请求由设备直接发送给你选择的服务商，不经过“纪要”服务器。</li>
  <li><strong>纪要 Pro 模式</strong>：云端转写与 AI 纪要由<strong>阿里巴巴 DashScope（百炼）</strong>提供——音频与文本由设备直接加密发送至该服务商处理（实时转写服务地址：dashscope.aliyuncs.com）。“纪要”服务器仅签发短时效临时访问凭证，不接收、不中转、不存储你的音频或任何文本。</li>
  <li><strong>数据位置</strong>：使用云端能力时，相关音频/文本片段将传输至上述服务商位于中国大陆的服务器处理；如你在境外使用，请知悉该跨境传输事实。</li>
</ul>
<h2>联系我们</h2>
<p>如有疑问，请联系：<a href="mailto:support@manymind.chat">support@manymind.chat</a></p>`, true);
}

export function termsHTML(): string {
  return page('使用条款 · 纪要', `
<h1>使用条款</h1>
<p class="meta">生效日期: 2026-07-30 · 纪要</p>
<h2>服务说明</h2>
<p><strong>纪要</strong> 提供会议录音、实时转写、智能纪要生成及相关效率功能。下载、安装或使用本应用即表示你同意接受本条款。</p>
<h2>订阅与自动续订</h2>
<p>纪要 Pro 为自动续订订阅服务，提供月度（¥25）与年度（¥198）两种规格，通过 Apple App Store 账户结算。</p>
<ul>
  <li>订阅会在当前周期结束前 24 小时内自动续费扣款，你可在「iOS 系统设置 → Apple ID → 订阅」中随时取消。</li>
</ul>
<h2>用户内容归属</h2>
<p>你在“纪要”中创建或导入的所有音频、转写文本及纪要笔记均完全归你所有。</p>`, true);
}

export function supportHTML(): string {
  return page('支持与帮助 · 纪要', `
<h1>支持与帮助</h1>
<p class="meta">纪要 支持中心</p>
<h2>联系我们</h2>
<p>官方支持邮箱：<a href="mailto:support@manymind.chat">support@manymind.chat</a></p>
<h2>我的会议数据安全吗？</h2>
<p>默认完全存储在你 iPhone/iPad 本地数据库中。进行云端转写与总结时，音频直接在设备与 AI 供应商之间传输，不经过“纪要”服务器中转或留存。详见 <a href="/privacy">隐私政策</a>。</p>`, true);
}
