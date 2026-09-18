# 循环计划 v2.7.0 · H3 健康异常提醒（第 13 类的诚实子集）

> 流程：编排 → 自审 → 实现 → 自检 → 发布。

## 目标
M2-H3：健康异常报警。**机制冲突审计后收窄范围**（见自审）。

## 现状
- 已有 `.alertHealthMilestone`：健康度跨过 90/85/80 时提醒
- 温度：`.alertHighTemperature` / `.alertTempSurge` 已存在
- HourlyTempStats 是「每小时历史最高温」，**不足以**支撑「连续 N 天持续超温」而不编造

## 本轮范围（收窄后）
1. **30 天健康度降幅** ≥ 阈值（默认 5 个百分点）→ 提醒
2. **循环数里程碑**（默认 800/1000）→ 提醒（与现有 health milestone 并行、去重键分离）
3. **不做**：持续高温新类型（数据不足，用现有高温提醒，避免谎报）

## 设计
- 纯函数 `HealthAnomalyDetector`
  - `healthDeclineFinding(samples:thresholdPoints:windowDays:)`
  - `cycleMilestoneFinding(cycleCount:lastSeen:thresholds:)`
- AppConfiguration 新字段 decodeIfPresent + clamp
- AlertController：读 healthSamples/cycleCount，`send` 走既有免打扰/权限门
- 开关：复用 `.alertHealthMilestone`（同属健康报警族，避免 DisplayOption 膨胀）

## 自审
| # | 问 | 结论 |
|---|---|---|
| 1 | 与里程碑打架？ | decline/milestone 用不同 notification id 与 defaults 键 |
| 2 | 免打扰？ | 复用 send() |
| 3 | 温度持续？ | 不做，防数据不足编造 |
| 4 | 换电池边界？ | samples 应已按序列号切开；decline 窗内跨边界时两端都是新电池才告警——用 recorder 过滤后样本 |
| 5 | 变异 | 阈值写反、窗口算错必红 |
| 6 | 自检/代理/玻璃 | 同前 |

## 版本
**2.7.0**
