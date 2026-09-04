# 妙电 MiaoDian

macOS 菜单栏电池监控工具,基于开源项目 [ChargeMonitor](https://github.com/CrashSystemZ/ChargeMonitor) 的汉化增强版。全部数据只在本机处理,不联网、不上传。

## 功能一览

- **菜单栏显示**:电量图标(精确到 1% 的自绘填充)/ 温度 / 功耗 / 剩余时间 / 24 小时走势图 / 三页轮换,充电时图标播放流光动画

- **状态面板**:充电协议与协商档位、输入/充电/整机功率(SMC 实时读取)、循环次数、健康度、电池温度、电流电压、电池身份证(电芯厂商/生产日期/电芯均衡)

- **图表卡片**:功耗曲线、温度曲线、24 小时电量走势、健康趋势与寿命预测、用电日历热力图、时段用电热力图、今日小结、充电记录(含每次充电曲线)

- **智能分析**:电池体检评分、掉电速度与续航场景换算、用电异常检测、充电习惯建议、充电器档案与劣质线材识别(系统认不出的第三方头可**用户自行命名**，同瓦数不同头按 PD 档位表分开建档)、会话级"是谁充的"速度对比、电池更换自动识别(健康趋势不被换电池骗)、电量计跳变监测

- **提醒通知**:充满 / 低电量及预判 / 高温与骤升 / 慢充 / 耗电异常点名应用 / 睡眠掉电(点名阻止睡眠的进程) / 健康里程碑 / 周报月报,免打扰时段可配,防轰炸设计;保养提醒可一键延后,慢充可复制诊断信息

- **数据自主**:历史数据本地存储并带滚动备份,一键导出纯文本报告 / CSV / 体检分享卡片 / 全量历史存档(换机迁移)

- **快捷指令**:内置「电池速览」App Intent,可在 Shortcuts、Spotlight 中直接查询当前电量与健康状态

## 截图

> 面板实拍图待补（欢迎 PR）：妙电面板为自适应双列布局，含电源信息、电池身份证、健康趋势预测、时段用电热力图等 18 种卡片。

## 安装

从 [Releases](https://github.com/yuting-ou/MiaoDian/releases) 下载最新 DMG,拖入应用程序文件夹即可。universal binary(arm64 + x86\_64),需 macOS 15+。

> 注意:本 fork 不走上游的 Homebrew 渠道,也没有应用内更新机制,请以 Releases 页为准。

## 从源码构建

只需 Command Line Tools,无需完整 Xcode:

```bash
bash build.sh    # 先跑单元测试(442 项断言),全过才编译打包
```

产物输出到 `输出/妙电.app`。`bash 打包.sh` 额外生成可分发的 DMG。

## 开发说明

- Swift 5 语言模式 + `-default-isolation MainActor`(Swift 6 全局隔离检查零错误)

- 所有时间相关判定抽为 `nonisolated` 纯函数,`now` 可注入,状态机直测真代码

- 单元测试与主程序共用源文件编译:`bash 测试/run_tests.sh`

- 推送自动跑 CI:`.github/workflows/tests.yml`

详见 [AGENTS.md](AGENTS.md) 与 [ChargeMonitor/README.md](ChargeMonitor/README.md)(上游原文)。完整版本历史见 [CHANGELOG.md](CHANGELOG.md)。

## English

MiaoDian is a Chinese-localized, heavily enhanced fork of [ChargeMonitor](https://github.com/CrashSystemZ/ChargeMonitor) — a macOS menu-bar battery monitor built with Swift/SwiftUI. It shows live power/temperature/SoC charts, battery health & identity, charger diagnostics, and 14 kinds of local notifications (low battery, high drain, sleep drain with culprit naming, weekly/monthly digests). Everything stays on your Mac — no network, no telemetry. Build with `bash build.sh` (Command Line Tools only, macOS 15+, universal binary); tests run first as a build gate.

## 致谢与许可

- 原项目:[CrashSystemZ/ChargeMonitor](https://github.com/CrashSystemZ/ChargeMonitor)

- 本仓库以 [MIT](LICENSE) 许可开源,汉化与功能增强部分同样遵循 MIT

