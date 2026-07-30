/** Recap 官网 + 法务页(托管在 recap.manymind.chat)。
 *  设计语言呼应 App:中性黑白灰 + 朱砂红(cinnabar)+ 纸白卡片 + 克制留白,移动优先。
 *  ⚠️ 法务内容为草稿,上线前请经法务/专业审核并确认主体信息。 */

const STYLE = `
:root{color-scheme:light dark;--ink:#1a1a1a;--tea:#6b7280;--tea2:#9ca3af;--paper:#ffffff;--bg:#fafafa;--bg2:#f3f4f6;--cinnabar:#E25C3F;--hairline:#e5e7eb;--radius:14px}
@media(prefers-color-scheme:dark){:root{--ink:#e8e8e8;--tea:#9aa0a6;--tea2:#6b7280;--paper:#16191d;--bg:#0e1116;--bg2:#14181d;--hairline:#262b32}}
*{box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue","PingFang SC",sans-serif;background:var(--bg);color:var(--ink);margin:0;line-height:1.7;font-size:16px;-webkit-font-smoothing:antialiased}
a{color:var(--cinnabar);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:760px;margin:0 auto;padding:0 22px}
header{position:sticky;top:0;z-index:10;background:var(--bg);opacity:.96;border-bottom:1px solid var(--hairline)}
header .wrap{display:flex;align-items:center;justify-content:space-between;padding:14px 22px}
.brand{font-weight:800;font-size:18px;color:var(--ink);letter-spacing:-.01em}.brand .dot{color:var(--cinnabar)}
.navlinks a{color:var(--tea);font-size:14px;margin-left:18px}
.hero{text-align:center;padding:72px 0 52px}
.hero h1{font-size:clamp(30px,7vw,46px);font-weight:800;letter-spacing:-.025em;margin:0 0 18px;line-height:1.15}
.hero .sub{font-size:clamp(16px,2.4vw,18px);color:var(--tea);max-width:560px;margin:0 auto 28px}
.cta{display:inline-block;background:var(--cinnabar);color:#fff;padding:15px 34px;border-radius:999px;font-weight:600;font-size:16px}
.cta:hover{text-decoration:none;filter:brightness(1.06)}
.cta-note{margin-top:14px;font-size:13px;color:var(--tea2)}
section{padding:36px 0}
.section-title{font-size:13px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--tea2);margin:0 0 18px;text-align:center}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:14px}
@media(max-width:560px){.grid{grid-template-columns:1fr}}
.card{background:var(--paper);border:1px solid var(--hairline);border-radius:var(--radius);padding:22px}
.card .ic{font-size:24px;margin-bottom:10px}
.card h3{font-size:16px;margin:0 0 6px}.card p{font-size:14px;color:var(--tea);margin:0}
.banner{background:var(--paper);border:1px solid var(--hairline);border-left:3px solid var(--cinnabar);border-radius:var(--radius);padding:22px 24px}
.banner h3{margin:0 0 6px}.banner p{margin:0;color:var(--tea);font-size:15px}
.pro{background:var(--paper);border:1px solid var(--hairline);border-radius:var(--radius);padding:26px;text-align:center}
.price{font-size:14px;color:var(--tea)}.price b{color:var(--ink);font-size:20px}
.doc{padding:52px 0 80px}
.doc h1{font-size:28px;margin:0 0 6px}.doc .meta{color:var(--tea2);font-size:13px;margin-bottom:26px}
.doc h2{font-size:18px;margin:28px 0 8px}
.doc p,.doc li{font-size:15.5px}.doc ul{padding-left:20px}.doc li{margin:7px 0}
footer{border-top:1px solid var(--hairline);padding:28px 0 44px;color:var(--tea);font-size:13px;text-align:center}
footer a{margin:0 6px}
`;

function page(title: string, body: string, doc = false): string {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<meta name="description" content="Recap —— 会议录音、实时转写与智能纪要,本地优先。">
<style>${STYLE}</style></head><body>
<header><div class="wrap"><a class="brand" href="/">Recap<span class="dot">.</span></a>
<nav class="navlinks"><a href="/privacy">隐私</a><a href="/terms">条款</a><a href="/support">支持</a></nav></div></header>
<main class="${doc ? 'doc' : ''}"><div class="wrap">${body}</div></main>
<footer><div class="wrap">
<a href="/privacy">隐私政策</a>·<a href="/terms">使用条款</a>·<a href="/support">支持</a><br>
<a href="mailto:support@manymind.chat">support@manymind.chat</a> · © 2026 Recap · manymind.chat</div></footer>
</body></html>`;
}

export function landingHTML(): string {
  return page('Recap · 会议转写与纪要', `
<div class="hero">
  <h1>每一场会议<br>皆成可阅笔记</h1>
  <p class="sub">Recap 把会议录音转为实时转写、结构化纪要与待办。本地优先——录音默认只留在你的设备。</p>
  <a class="cta" href="#">获取 Recap</a>
  <div class="cta-note">App Store · iOS</div>
</div>
<section><p class="section-title">核心能力</p>
  <div class="grid">
    <div class="card"><div class="ic">🎙️</div><h3>端侧转写</h3><p>Apple Intelligence 设备上完成识别,音频不上传,完全离线可用。</p></div>
    <div class="card"><div class="ic">☁️</div><h3>云端高保真</h3><p>阿里 Fun-ASR,嘈杂场景与方言同样准确;自动区分发言人。</p></div>
    <div class="card"><div class="ic">📝</div><h3>智能纪要</h3><p>结构化总结、决议、待办与要点,会后一键生成。</p></div>
    <div class="card"><div class="ic">🔒</div><h3>隐私优先</h3><p>本地存储;云端转写时音频直连供应商,不经 Recap 服务器。</p></div>
  </div>
</section>
<section>
  <div class="banner"><h3>音频从不经过 Recap 服务器</h3>
    <p>使用云端转写时,你的设备直接与供应商(阿里云)通信。即便订阅 Recap Pro,我们也仅签发短期访问凭证,不接收、不中转、不存储你的音频或内容。</p>
  </div>
</section>
<section><p class="section-title">Recap Pro</p>
  <div class="pro">
    <p class="price"><b>¥25 / 月</b>&nbsp;&nbsp;或&nbsp;&nbsp;<b>¥198 / 年</b></p>
    <p style="color:var(--tea);margin:12px 0 0">云端高保真转写 + 强模型纪要,免配 API Key。通过 Apple 订阅,可随时取消。</p>
  </div>
</section>`);
}

export function privacyHTML(): string {
  return page('隐私政策 · Recap', `
<h1>隐私政策</h1><p class="meta">Recap · 生效日期:2026-07-30</p>
<h2>概述</h2>
<p>Recap 采用<strong>本地优先</strong>设计:你的录音、转写文本、纪要与手写笔记<strong>默认仅保存在你的设备上</strong>,我们不运营存储你会议内容的服务器。</p>
<h2>我们处理的数据</h2>
<ul>
<li><strong>录音与内容</strong>:音频在本机落盘,转写、纪要、手写笔记存储于本机数据库。除非你主动导出或启用云端能力,内容不会离开设备。</li>
<li><strong>账户(可选)</strong>:可选择「通过 Apple 登录」或本地使用,仅保留 Apple 返回的用户标识与昵称,不持有密码。</li>
<li><strong>订阅状态</strong>:Pro 通过 Apple App Store 完成,支付由 Apple 处理,我们仅收到订阅是否有效的状态。</li>
</ul>
<h2>云端转写与纪要</h2>
<ul>
<li><strong>自备密钥</strong>:你自行配置厂商密钥时,音频与请求<strong>由设备直接发送给你选择的供应商</strong>(如阿里云、DeepSeek),<strong>不经过 Recap 服务器</strong>。</li>
<li><strong>Recap Pro</strong>:音频与请求由设备<strong>直接发送给我们的供应商(阿里云)</strong>。Recap 服务器<strong>仅签发一个短期访问凭证(数分钟有效)</strong>,<strong>不接收、不中转、不存储</strong>你的音频或内容。</li>
</ul>
<h2>第三方服务</h2>
<p>依使用方式,数据可能被以下第三方处理(受其隐私政策约束):Apple(订阅与登录)、你自行配置的模型/语音供应商、阿里云(Pro 会员模式)。</p>
<h2>数据删除</h2>
<p>你可在 App 内随时删除任意会议或全部数据;账户偏好可在设置中删除,删除后不可恢复。</p>
<h2>关于会议录音</h2>
<p>录音前你有责任遵守当地法律,并在必要时获得所有参与者同意。Recap 不对录音的合法性承担责任。</p>
<h2>儿童</h2>
<p>Recap 不面向 13 岁以下儿童, knowingly 不收集其信息。</p>
<h2>联系我们</h2>
<p><a href="mailto:support@manymind.chat">support@manymind.chat</a></p>`, true);
}

export function termsHTML(): string {
  return page('使用条款 · Recap', `
<h1>使用条款</h1><p class="meta">Recap · 生效日期:2026-07-30</p>
<h2>服务说明</h2>
<p>Recap 提供会议录音、实时转写、纪要生成及相关功能。使用即表示你同意本条款。</p>
<h2>订阅与自动续期</h2>
<p>Recap Pro 为自动续期订阅,提供月度(¥25)与年度(¥198),通过 Apple App Store 结算。</p>
<ul>
<li>订阅会在到期前 24 小时内自动续费,除非你至少提前 24 小时关闭自动续期。</li>
<li>可在「系统设置 → Apple ID → 订阅」随时管理或取消。</li>
<li>已支付费用不予退还,但可继续使用至当前周期结束。</li>
</ul>
<h2>用户责任</h2>
<ul>
<li>你须合法使用本服务,并对所录内容的合法性承担全部责任,包括录音前取得必要同意。</li>
<li>不得用于违法或侵犯他人权利的活动。</li>
</ul>
<h2>用户内容</h2>
<p>你创建的所有内容(录音、转写、纪要)归你所有,我们不对其主张权利。</p>
<h2>服务「按现状」提供</h2>
<p>本服务以「现状」和「可用」为基础提供,不就适销性、特定用途适用性或不侵权作任何明示或暗示保证。</p>
<h2>责任限制</h2>
<p>在适用法律允许的最大范围内,对任何间接、附带或后果性损失,我们不承担责任。</p>
<h2>条款变更</h2>
<p>我们可能更新本条款,重大变更会在 App 内或本页告知,继续使用即视为接受。</p>`, true);
}

export function supportHTML(): string {
  return page('支持 · Recap', `
<h1>支持</h1><p class="meta">遇到问题?我们很乐意帮忙。</p>
<h2>联系我们</h2>
<p>邮件:<a href="mailto:support@manymind.chat">support@manymind.chat</a></p>
<h2>转写不工作?</h2>
<p>支持 Apple Intelligence 机型的端侧转写(免费),以及云端高保真转写(自备密钥或 Pro 会员)。请在「设置 → 转写」确认所选引擎与凭证。</p>
<h2>如何取消订阅?</h2>
<p>「系统设置 → Apple ID → 订阅」,选择 Recap Pro 取消即可。</p>
<h2>我的数据在哪?</h2>
<p>默认仅在你的设备上。云端转写时音频直连供应商,不经 Recap 服务器。详见<a href="/privacy">隐私政策</a>。</p>`, true);
}
