---
feature: panel-scroll-drag
status: in-progress
updated: 2026-09-16
branch: panel-scroll-drag
commits: 0dd1365c279dada9927e5126014e757c9137ee04..HEAD
---

# 面板高度滚动 + 拖拽人体工学收尾

## Report

## [S1] Problem

用户卡片集下面板自然高约 1101pt，可视区（菜单栏与 Dock 之后）约 987pt：底部约 4 行控制项压在 Dock 下点不到。间距压缩已到极限（v2.1.2 观感整改实测），根治只能是「装不下才滚动」或减卡。工作区已有未提交半成品实现了滚动门控与拖拽改进，但缺测试锁、有一处重复实现，尚未收尾。

拖拽侧半成品已落地：整卡可拖（10pt 阈值，把手仍保留 0 距离明示抓取点）、落点指示线、弹簧参数收紧；`CardDropResolver.indicatorLine` 纯函数已进引擎，但视图层另有一份等价私有副本。

## [S2] Design

**高度预算（PanelFit）**

- 判定纯函数 `PanelFit.budget(naturalHeight:visibleFrameHeight:chromeHeight:)`：
  - `available = max(360, visibleFrameHeight − 8 − chromeHeight)`
  - `scrolls = natural > available`
  - `contentHeight = min(natural, available)`
- `MenuBarPanelController.showPanel` 两遍布局：先用离屏 `NSHostingView` 量自然高，仅当 `scrolls` 时把 `BatteryPopoverView` 包进竖向 `ScrollView`（frame 固定为可用高）；否则原路径，零行为变化。
- chrome：`.titled + fullSizeContentView` 下 `setContentSize` 只给内容矩形，窗口框仍多出隐形标题栏高度，须从可视区扣除。
- 日志：滚动启用时写 `info` 级 `PanelScroll` Logger，不走 error 级（保持健康检查零错误日志）。
- **不做**：卡片自动隐藏、横向滚动、改布局骨架、改卡片渲染。

**拖拽指示线**

- 几何唯一来源：`CardDropResolver.indicatorLine(for:table:excluding:)`——`before(key)` 画在锚卡上沿外 4pt，`.end` 画在末卡下沿外 4pt；排除被拖卡；空表/锚点缺失返回 nil。
- 视图层只消费该函数，不得再维护第二份几何。`resolve` 返回 nil 时清空 `dropIndicator`，避免线冻在上一合法缝隙。
- 把手与卡片本体共用 `dragGesture(for:minimumDistance:)` 状态机；幽灵拖拽守卫保留。

**滚动 × 整卡拖拽仲裁（审查 CRITICAL）**

- `simultaneousGesture(DragGesture)` 与竖向 `ScrollView` 争同一段 pan：想滚却把卡提起来。
- 契约：`BatteryPopoverView.allowsCardDrag`（默认 true）；滚动宿主建根时传 false，卡片本体手势 `including: .none`，把手手势不受影响。
- 非滚动路径保持整卡可拖。

**滚动宿主风险**

- 1.1.1 曾在 MenuBarExtra 宿主给卡片区加 `ScrollView + maxHeight` 导致空白渲染。本次 frame 落在 ScrollView 外壳（固定可用高），内容不设 maxHeight；验收必须含实拍/程序化开面板，离屏量具只能验尺寸。

## [S3] Out of Scope

- v2.1.2 其余「等眼睛」项（折叠摘要字号统一、空态卡继续收高）
- 路线图 M1-C3/C4/C5 与 M2
- 发版/tag/Release（本 feature 随 2.1.2 未发版线一起走，不在本轮单独发）

## Tasks

- [x] T1: 视图层去重，`dropIndicator` 走 `CardDropResolver.indicatorLine` — acceptance: `BatteryPopoverView` 不再定义私有 indicator 几何；行为等价
- [x] T2: `PanelFit.budget` 与 `indicatorLine` 补断言 + 变异检验 — acceptance: `bash 测试/run_tests.sh` 全绿；实现写反（scrolls 恒真/恒假、线画在卡内、不排除被拖卡）必有断言变红 (covers: S2)
- [x] T3: 全量验证（测试门 + Swift 6 审计 + 离屏高度门） — acceptance: 测试绿、审计零错误、离屏量具给出尺寸；若屏幕可用则程序化开面板确认非空白
- [x] T4: CHANGELOG v2.1.2 补滚动与拖拽条目 — acceptance: 与实现一致，不宣称未做的验收
