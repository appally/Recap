# 第二次 4.3(a) 应对卷宗（2026-08-16）

> 背景：8-14 首拒（4.3a + 2.1b + 3.1.2c），8-15 修复后重提，8-16 再次被拒，
> 仅剩 4.3(a)（2.1b / 3.1.2c 已通过）。本文记录调研证据、元数据重写依据、
> 新回信草稿与升级预案。元数据成品以 `app store.md` 为准。

## 一、调研结论：我们为什么「长得像」spam

### 1. 品类环境（iTunes Search API 实测，2026-08-16）

中国区搜「纪要」的 24 个结果**全部**是 AI 录音转写类应用，其中：

| 应用名 | 开发者 | 评分数 | 备注 |
|---|---|---|---|
| 纪要大师-AI语音转文字 | Shenzhen Doutu Technology | 0 | 品类词壳应用 |
| AI会议纪要 · 语音转文字 · AI智能笔记助手 | CLIXADE LTD | 0 | 品类词+关键词堆叠名 |
| 通义听悟 - 会议记录 语音转文字 会议纪要神器 | Gina Estrella（个人） | 232 | **冒名阿里的山寨** |
| Omi AI：录音转文字与会议纪要 | Based Hardware INC | 1 | 海外壳 |
| Atter AI：语音转文字·录音转文字助手·会议纪要神器 | Oceanic Digital, Inc | 275 | 堆叠名 |
| AUV·听记 / Nib / iMemo / Flownote / 倾耳 / 简单录 / 随声录音转文字 … | 各类壳公司/个人 | 0~525 | 同簇 |

**解读**：这个品类正是 Apple 中国区 4.3(a) 清洗重灾区，审核员每天从这条搜索
结果页流过几十个「品类词命名 + 转写关键词堆叠」的应用。我们叫「纪要」，
审核员第一眼的模式匹配就落进这个簇——**名称即品类词，是被误判的根源之一**。

反向证据：存活的健康应用全部用品牌名（随身鹿、得到大脑、倾耳、Meet妙记、
简单录、讯飞听见），不用品类词命名。

### 2. 我们旧元数据里的模板签名（上次只清了 Plaud 词，骨架没动）

对比「随身鹿」「听脑AI」描述实测样本，旧版 `app store.md` 与之共享同一骨架：

| 模板签名 | 旧版我们的 | 竞品簇 |
|---|---|---|
| 痛点反问两连开场 | ✅（开会讨论天马行空…？） | ✅ |
| 「为什么选择X？」 | ✅ | ✅（随身鹿原句） |
| 一、~七、 分栏 + 1.2.3. 子项 | ✅（七大类） | ✅ |
| 适用场景四连（冒号排比） | ✅ | ✅ 原句同构 |
| 副标题「A，B｜C、D与E」关键词簇 | ✅ | ✅（堆叠名同构） |
| 「立即下载X，体验全新方式！」CTA | ✅ | ✅ |
| 关键词与竞品清单大面积重叠 | ✅ 15词中12词 | — |

**结论**：上次的修复（删 Plaud/飞书）只去了「内容相似」，没去「结构相似」。
审核员 30 秒扫一眼，结构相似就足以触发「又一个套壳」判断。

## 二、重写策略：三个换法

1. **结构换成产品自述**：删掉全部 ASO 模板件（【】块/分栏编号/适用场景四连/
   极限词/品牌堆叠/下载CTA）。描述改成开发者本人口吻，872 字（远低于 4000，
   长描述堆砌本身就是 spam 信号）。
2. **主张换成「竞品簇没有的东西」**：主叙事从「录音转文字」换成
   **「一场会议的三种笔迹：说话、手写、拍照」**——这是品类内无人组合的
   概念，且三项均为真实功能。声纹表述精确化为「跨会议认出你」（随身鹿只有
   单场内声纹区分，不可与其撞表述）。可核实数字全部对齐代码：23 个模板
   （AgentBundledSkills.swift 实测 23 项）。
3. **关键词去簇**：不再与头部应用正面堆叠「会议纪要/实时转写/录音/会议记录」
   （旧 15 词中 12 词与竞品重叠），主打差异化长尾（声纹识别/方言/板书/
   离线转写…），仅留「录音转文字」一个头部词，零品牌名。

## 三、本轮 Resolution Center 回信（新稿，回复本次 4.3(a)）

> 直接粘贴到 Resolution Center；可附 2~3 张独有功能截图（手写入稿/
> 拍照锚定/声纹标记）。签名档补姓名。

Hello,

Thank you for the feedback, and for confirming that the 2.1(b) and 3.1.2(c)
items from the previous round are resolved.

We have taken the 4.3(a) concern seriously and looked hard at our listing.
On review, we found the issue was real, though unintentional: our previous
subtitle, keywords and description followed the structural template that is
extremely common among voice-recording apps on the China storefront
(keyword-clustered subtitle, numbered feature categories, boilerplate
scenario lists). That structure made an independently developed app look
like the low-quality clones in this category. In this submission the entire
listing has been rewritten:

- The subtitle now states the app's own concept — "recording, handwriting,
  photos: three instruments in one meeting" — instead of a keyword cluster.
- The description is written in the developer's own voice, organized around
  capabilities that, to our knowledge, no other app in this category
  combines: fully on-device offline transcription on supported devices,
  Apple Pencil handwriting recognized and merged into the minutes,
  whiteboard/slide photos time-anchored into context, cross-meeting speaker
  identity using locally processed voiceprints, and human-in-the-loop todo
  confirmation that syncs to Reminders.
- Keywords no longer mirror the category's saturated head terms.

The app itself remains entirely original work: developed from scratch by a
single developer, over 270 Swift source files, with continuous commit
history we are happy to provide as evidence. No app template was purchased
or used.

We would also welcome the opportunity to talk through any remaining
concerns by phone, at a time convenient for the team.

Best regards,
[开发者姓名]
support@manymind.chat

## 四、随本轮提审的其他核查

- [ ] ASC 同步新副标题/关键词/描述（与 `app store.md` 逐字一致；回信已宣称 rewritten，不一致即坐实）
- [ ] 截图核查：前两张必须展示**独有界面**（Pencil 手写层 / 拍照锚定 / 声纹「标记我」），
      不用纯文字卖点轮播图（那也是簇内签名）；现有纸面组视觉本身差异化强，保留
- [ ] 审核备注已补「独有能力演示」路径（app store.md 第五节第 4 条）
- [ ] 若描述截断显示：首三行是「会开完，最累的…/ 不是又一个录音转文字工具 /
  第一支笔」——折叠线上方已承载差异化主张，无需调整

## 五、若第三次仍以 4.3(a) 拒（升级预案，按序执行）

1. **预约审核电话**（developer.apple.com/contact/topic → App Review →
   Request a call）：4.3 争议电话沟通成功率显著高于纯文字；要点=原创证据
   （git 历史）+ 独有功能当场演示 + 已配合重写元数据的记录。
2. **提交 App Review Board 申诉**（appeal）：引用本轮已实质重写元数据的事实。
3. **届时再议改名**：本次拍板保留「纪要」；若三拒，改名是从搜索结果页
   「脱簇」的最后杠杆（本卷宗第一节表格即证据）。候选方向（届时需重名核查）：
   墨纪 / 笔落 / 拾音纪——均保留「书写感」，可平滑迁移「问纪要/纪要Pro」命名。
