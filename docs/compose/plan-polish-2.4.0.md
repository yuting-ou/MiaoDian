# 打磨计划 v2.4.0（编排稿 · 自审后执行）

> 用户指令：按推荐顺序做；**先编排 → 自审校对 → 再动手**。  
> 范围：C4 收尾 + C5 + 驻留洞察/周报 + H1 + R9/文档。  
> 纪律：纯函数+测试；UI 只加法；交付前自检；代理自行探测；禁玻璃 drawingGroup。

## 0. 范围与不做

| 做 | 不做（本轮） |
|---|---|
| C4 涓流「活着时」面板侧露出 | 月级曲线、充电控制 |
| C5 存放建议（洞察一条，不新建高卡） | 大改布局骨架 |
| 驻留洞察 + 周报带驻留 | H2/H3/H4、M3 全量 |
| H1 健康口径 help 一句话 | 折叠字号统一（等眼睛） |
| R9 预览警告 + 文档数字 | 改 CI runs-on（无 macos-27） |

## 1. 现状对账（代码事实）

- **C4 已有**：`ChargingPhase` 判定 + 功率行「·涓流补足」+ 曲线 80%/95% 虚线（`UsagePatternAnalyzer`/`BatteryInfoFormatter`/`ChargeCurveDetailView`）。
- **C4 缺口**：面板**当前**涓流时无稳定一眼文案（除功率后缀）；曲线未标注「涓流段」文字解释。
- **C5 缺口**：无任何存放引导。
- **C3 已有**：`DwellTracking` + 日摘要行；**未进** `chargingInsights` / 周报。
- **H1 缺口**：健康行有 mAh 分子分母，**无**「与系统口径差异」说明；体检已有「含估计项」。
- **R9**：`测试/预览/main.swift` `#IsolatedConformances`。

## 2. 设计

### C4 收尾（薄）
- 纯函数：`ChargingPhase.liveNotice(soc:isCharging:)` → 涓流且在充时返回「系统涓流中：接近满电，输入功率主要供整机」
- 接入：洞察链末尾或功率卡悬停/help 已有 phase.explanation → **优先洞察一条**（不抬高度：并入现有 insight）
- 曲线：hover 到 ≥95% 点时 label 带「·涓流」（改 `hoverLabel`）；分区线文案已有
- **不承诺控制**

### C5 存放（洞察一条，非独立卡）
- 纯函数 `StorageGuide.advice(socPercent:isOnAC:)`：
  - `isOnAC && soc >= 80` →「若要长期存放，建议充到 50–60% 再拔电」
  - `!isOnAC && soc >= 45 && soc <= 65` →「当前电量适合长期存放」（可低频）
  - 其余 → nil（不打扰）
- 接入 `chargingInsights`，symbol `archivebox.fill`；**不与** C1 预设抢设置页

### 驻留洞察 + 周报
- `DwellTracking.trackingInsight(history:today:calendar:)` → `ChargingHabitInsight?`
  - 对比 delta ≤ -15 分钟且 recent 有样本 → 正向「驻留日均下降」
  - delta ≥ 15 且 recentAvg ≥ 90 →「驻留偏高，可试办公 80% 预设」
  - 样本不足 → nil
- `chargingInsights(... dwellInsight:)` 插入顺序：习惯 → 打架 → 热 → **驻留** → 慢充 → **涓流/存放**（待定：存放/涓流放末尾）
- `weeklyDigestBody` 增加可选 `dwellLine: String?`：`DwellTracking.weeklyDigestLine(history:due:calendar:)` 有对比才附一句

### H1 健康口径
- 纯函数 `HealthCaliber.disclosure(hasDesign:hasRawMax:) -> String`
- 恒定 help：「健康度按 AppleRawMaxCapacity/设计容量 直算，与系统设置可能差 1–2%（口径与刷新周期不同）；体检含估计项时会在卡上标明。」
- 挂 `healthItem.helpText`（BatteryInfoItem 已有 help）

### R9 + 文档
- 预览 `PreviewAppDelegate`：`@preconcurrency` 或 `nonisolated` 符合，消警告
- README/CHANGELOG/作业书：测试数、C3/C4/C5/H1 状态、发布线 v2.4.0

## 3. 实现顺序

1. 纯函数：`StorageGuide`、`DwellTracking` 扩展、`ChargingPhase.liveNotice`、`HealthCaliber`、周报 line  
2. 测试 + 变异  
3. UI 加法：`chargingInsights` 签名、`BatteryPopoverView.habitInsights`、`weeklyDigestBody` 调用、曲线 hover、health help  
4. R9 修复  
5. 全门自检 → bump **2.4.0** → 打包安装 → 推送（自探测代理）  
6. CHANGELOG / 迭代报告 / 作业书  

## 4. 自审（校对记录）

| # | 审什么 | 结论 |
|---|---|---|
| 1 | 是否违背「只提示不干预」？ | 否；C4/C5 均为文案 |
| 2 | 是否新建高卡加剧超屏？ | 否；洞察一行 + help，不新建卡 |
| 3 | C3 数据不足会不会瞎说？ | 对比两侧 minDays=2/3，不足 nil |
| 4 | C5 会不会天天刷屏？ | 仅 AC≥80 或在存放带时；并入洞察可关（habitInsight 开关） |
| 5 | 洞察顺序与打架/静默是否冲突？ | 驻留不依赖系统 hold；顺序文档化 |
| 6 | 周报是否改签名破坏测试？ | 加参数带默认/重载，旧测试可改 |
| 7 | H1 help 是否撒谎？ | 口径来自 IOKit AppleRaw 已实现；用「可能差 1–2%」不给假精确 |
| 8 | R9 是否在 CI 审计面？ | 否（只收 ChargeMonitor/**），仍应修 |
| 9 | 门面数字 | 实测后一次改 README/CHANGELOG/作业书 |
| 10 | 代理 | 推送前 scutil+lsof 探测，不信 env |
| 11 | 玻璃/滚动红线 | 不碰 ScrollView 骨架、不 drawingGroup |
| 12 | 质量门槛三问 | 后果具体（说谎/看不见驻留效果）；一轮可完；纯函数可测 |

**修订**：原计划「独立存放卡」改为洞察一条——高度门与卡片资格门成本过高（自审 #2）。

## 5. 验收

- `bash 测试/run_tests.sh` 全绿且新断言覆盖：存放阈值、驻留洞察三态、周报有/无线、健康 help 非空、涓流 notice
- Swift 6 零错误；无 drawingGroup；玻璃路径 grep 通过  
- 安装后 `/Applications` 版本 = pbxproj；hash 与输出一致；日志无 error  
- GitHub：探测真代理后 push + Release  

## 6. 版本

**2.4.0**（功能：C4 露出 + C5 + 驻留洞察/周报 + H1；工程：R9/文档）
