# 循环计划 v2.9.0 · E4 动态续航精调

> 流程：编排 → 自审 → 实现 → 自检 → **对抗式审查** → 通过后才同步 GitHub。
> 透镜：数据完整性 + 自身成本 + 可溯源（估计质量）。

## 目标（M3-E4）

公理一「估计质量」：剩余电量 ÷ 净放电率。本轮精调两件事：

1. **窗口自适应**——负载突变时估算能跟上（现在固定 60 分钟窗）
2. **场景系数·本机强度校准**——用本机 DailyUsage 历史相对强度，有界夹紧出厂系数（**不是** per-scenario 回归，计划与文案均写明）

**不做**（能量悖论审计结论，写进代码注释与 CHANGELOG）：
- 亮度因子：需持续读显示子系统/私有接口，轮询成本与权限均不过关；事件驱动一次性读也不足以支撑场景系数
- 网络因子：采样成本 + 隐私面扩大，本轮拒绝
- 场景标签真回归：历史无「用户当时在开会还是轻度」标注，**不能假装**从 drainedPercent 回归出 per-scenario 系数

## 现状

| 组件 | 现状 | 缺口 |
|---|---|---|
| `DrainRateEstimator` | 固定 60min 窗，minSpan 10min；库仑计数优先 | 负载突变后旧样本拖慢响应（快→慢/慢→快都钝） |
| `RuntimeScenario.drainMultiplier` | 写死 0.65 / 1.25 / 1.7 | 不随本机近期用电强度变化 |
| `DailyUsage` | 已有 `drainedPercent` + `batterySeconds` | 可推日强度，**无需新 defaults 键** |
| 续航卡 | 展示三场景分钟数 | 未说明窗口口径 / 是否本机微调 |

## 设计

### A. 窗口自适应（纯函数，进 DrainRateEstimator.estimate 路径）

`nonisolated static func adaptivePercentPerHour(samples:...) -> Double?`

```
输入：[(date, percent)]，可注入 fullWindow/recentSpan/阈值
1. 取 fullWindow 内样本；full 窗 span≥minSpan 且 drop≥1 → fullRate
2. 取 recentSpan 内样本；recent 窗 span≥minRecentSpan 且 drop≥1 → recentRate
3. 两侧都有，且 |recent-full| ≥ mutationRatio * max(|full|, floor)
   → 返回 recentRate（突变响应）
4. 否则 → fullRate（稳定优先）
5. 两侧都无 → nil
```

默认：full=3600s，minSpan=600s，recentSpan=900s，minRecentSpan=480s，mutationRatio=0.35，floor=0.5%/h。

`estimate()` 改调此函数；库仑计数剩余时间路径不变。

### B. 场景系数·本机强度校准（纯函数，新文件 `RuntimeScenarioCalibration.swift`）

**诚实口径**：不是 per-scenario 回归，是「本机相对自身基线的放电强度」。

```
dayIntensity(day) = drainedPercent / batteryHours
  条件：batterySeconds ≥ 30min 且 drainedPercent > 0

intensityFactor(history, now, calendar) -> Double?
  recent  = 近 3 个有效样本日的日强度中位数
  baseline= 其前至多 14 个有效样本日（至少 5 日）中位数
  两侧样本不足 → nil（维持出厂系数）
  factor = recent/baseline，夹紧 [0.80, 1.25]

effectiveMultiplier(factory, factor?) -> Double
  factor==nil → factory
  否则 clamp(factory * factor, factory*0.85, factory*1.20)
  且总范围夹紧 [0.40, 2.50]（防异常日把系数打飞）
```

`RuntimeScenarioEstimator.estimates` 增加可选 `calibrationFactor: Double?` 参数；UI 在 factor≠nil 时卡片底部一行 help：「已按本机近期用电强度微调（×1.xx）」。

### C. UI（只做加法）

- `RuntimeScenarioSection` 增加 `calibrationFactor: Double?`
- 窗口自适应后副标题仍写「按当前掉电速度」；若 `estimate` 标注了短窗，可写「（近 N 分钟）」——本轮 `DrainRateEstimate` **可选**加 `windowSeconds: Int?`，decode 不涉及（非档）
- 不改布局骨架、不碰滚动体系

### D. 版本与队列

- **2.9.0**（新精调能力）
- W1 两周精度：预估 vs 实测掉电偏差目标 ±10%（报告写入验证法）
- E2/H4/W2 仍在队列

## 自审

| # | 问 | 结论 |
|---|---|---|
| 1 | 真做了「场景系数回归」吗？ | **没有**。历史无场景标签，只做相对基线强度因子；文案与 CHANGELOG 写明，避免过度承诺 |
| 2 | 新增 defaults 键？ | 否。强度从既有 DailyUsage 推导 |
| 3 | 能量悖论？ | 无新定时器/采样；亮度/网络审计后不做 |
| 4 | 数据缺失时显示什么？ | factor=nil → 出厂系数 + 无微调文案；窗口不足 → 不估算（现状） |
| 5 | 一轮可完？ | 纯函数+测试+卡片一行 help ≈150 行内 |
| 6 | 变异检验？ | ①突变场景固定 full 窗 → 断言红；②去掉夹紧 → 超范围红；③样本不足仍给 factor → 红 |
| 7 | UI 骨架？ | 不改；高度门不适用 |
| 8 | 旧档兼容？ | 无新持久化字段 |
| 9 | 最坏合法输入？ | 单日巨幅掉电（游戏日）→ 中位数+夹紧吸收；全历史只有 4 个样本日 → nil |
| 10 | 可溯源？ | 卡片 help 写明「本机近期强度」口径；不写假场景名 |

## 交付纪律

1. 计划（本文件）→ 自审 ✓
2. 实现 + 测试变异检验
3. 本机测试 + `TZ=UTC` 测试 + Swift 6 审计
4. **对抗式审查**（独立审：过度承诺/静默失败/能量悖论/系数边界/文案截断）
5. 审查阻断项清零 → 打包安装 → 再 push/tag/Release
6. 迭代报告 + 经验账本
