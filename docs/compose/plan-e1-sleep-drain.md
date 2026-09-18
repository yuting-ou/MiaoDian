# 循环计划 v2.6.0 · E1 睡眠耗电分析

> 流程：编排 → 自审 → 实现 → 交付前自检 → 发布 → 下一循环（E2/H3 按队列）。

## 目标（M3-E1）
痛点「合盖掉电快」：已有单次 `SleepDrainRecord` + 异常提醒 + 报告行；缺**聚合分析**——近期睡眠掉电水平、元凶排行、诚实建议（只建议不动作）。

## 现状
- `SleepDrainRecord`：sleep/wake、start/end percent、`dropPerHour`、`culpritNames`
- 面板信息行「睡眠掉电」只展示**最近一次**
- 提醒阈值：合盖≥1h、掉电≥5%、≥2%/h（`shouldAlertSleepDrain`）
- **无**周聚合、无跨次元凶排名

## 设计

### 纯函数 `SleepDrainAnalytics`
```
Analysis:
  sampleCount, avgPercentPerHour, maxPercentPerHour
  topCulprits: [String]   // 频次降序，最多 3
  advice: String?
```
- 筛选：`durationMinutes >= 60` 且 `droppedPercent >= 1`；可注入 `maxAgeDays`（默认 14）与 `now`
- `minSamples` 默认 3：不足 → nil（第一次透镜）
- 元凶：跨记录统计 `culpritNames` 频次
- `advice`：
  - avg≥2 →「近期合盖掉电偏快（约 X%/小时）；若有元凶：…。可在活动监视器查看是否阻止睡眠——妙电只提示不结束进程」
  - avg 1–2 →「近期睡眠掉电大致正常（约 X%/小时）」
  - 有元凶且 avg≥1.2 → 附加点名 Top
- **不做**：杀进程、改系统设置、合盖硬件检测（无传感器则不编造 clamshell 结论）

### UI（加法，不新建高卡）
- 扩展睡眠信息行 help 或在行下 9pt 一行：`SleepDrainAnalytics.summaryLine(analysis)`
- `DisplayOption.sleepDrainReport` 已有开关；聚合文案挂同一路径
- 报告 `BatteryReportBuilder` 可加一句聚合（可选，本轮先面板 help）

### 自审
| # | 问 | 结论 |
|---|---|---|
| 1 | 是否干预？ | 否，只提示 |
| 2 | 样本不足？ | nil / 不显示聚合句 |
| 3 | 元凶空？ | advice 不点名 |
| 4 | 新建卡高度？ | 不新建，help/行文案 |
| 5 | 与提醒打架？ | 聚合是回顾，提醒是瞬时；不改提醒阈值 |
| 6 | 变异 | 频次排序反了 / 门槛忽略 duration 必红 |
| 7 | 玻璃红线 / 自检 / 代理 | 同前 |

## 验收
- 断言：筛选、minSamples、排序、advice 三档、无元凶不点名
- 测试全绿 + Swift6 + 2.6.0 安装 + 代理推送 + CI

## 版本
**2.6.0**
