# 循环计划 v2.5.0 · H2 老化趋势置信表达

> 流程：编排 → 自审 → 实现 → 交付前自检 → 发布 → 进入下一循环（E1）。

## 目标
计划 M2-H2：外推到 80% 不再给单点「约 X 后」假精确，改为 **估计 + 置信区间 + 双锚点**；样本不足明说。

## 现状
- `TrendAndCalendarSections.projection`：首尾两点线性外推，跨度≥14 天且健康度在掉才显示
- 文案无区间、无「估计」字样；`projectionCaveat` 仅悬停
- `HealthSample` 含 `healthPercent` + `cycleCount?`

## 设计

### 纯函数 `HealthAgingProjection`（Utilities）
```
Result:
  remainingDaysP50, remainingDaysLow, remainingDaysHigh
  spanDays, sampleCount
  capacityDeclinePerDay, cycleDeclinePerDay?
  method: .capacityOnly | .dualAnchor
  isShortSpan: spanDays < 30
```
- **锚点1 容量斜率**：`(first.hp - last.hp) / spanDays`
- **锚点2 循环当量**：若有首尾 cycleCount，`(Δcycles / spanDays) * percentPerCycle`，`percentPerCycle = 0.02`（1000 循环→80% 的标称量级，纯估计常数）
- **合成**：双锚点都有时 `0.5*(cap+cycle)`；否则仅容量；cycle 无效（Δcycles≤0 或缺失）则忽略
- **门槛**：span≥14 天、last.hp>80、合成 decline>0；样本点<2 → nil
- **置信带**（相对半宽 `w`）：
  - span<30 → w=0.45
  - 30–90 → w=0.30
  - >90 → w=0.20
  - `low = p50*(1-w)`, `high = p50*(1+w)`（天数）
- **文案** `displayLine(result) -> String`：
  - 强制含「估计」
  - 区间用「约 X–Y」
  - shortSpan 追加「（样本偏短，区间更宽）」

### UI
- `lifespanText` 改调 `HealthAgingProjection` + `displayLine`
- 悬停 help：`projectionCaveat` + method 说明（双锚点/仅容量）
- **不改**卡片高度/骨架

### 自审
| # | 问 | 结论 |
|---|---|---|
| 1 | 假精确？ | 文案必含「估计」+区间 |
| 2 | 常数 0.02 是否撒谎？ | 悬停写明「标称循环当量，非你的电池实测」 |
| 3 | 健康不掉/跨度不足？ | nil，与现网一致 |
| 4 | 变异：区间反了/w 忽略 span/双锚点写成单锚点 | 断言锁 |
| 5 | 玻璃/滚动红线 | 不碰 |
| 6 | 门面数字 | 发版时实测刷齐 |
| 7 | 代理 | scutil+lsof 探测 |
| 8 | 交付自检 | 必做 |

## 验收
- 新断言：双锚点 vs 单锚点、区间单调 low<p50<high、shortSpan 标志、displayLine 含「估计」、cycle 无效回落
- 变异检验：`percentPerCycle=0` 时 dual 退化；`w` 反号必红
- 测试全绿 + Swift6 + 安装 hash + 代理推送 + CI

## 版本
**2.5.0**（功能 H2）
