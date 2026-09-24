# 电池管理（MiaoDian / 妙电）工作区说明

本工作区是 [CrashSystemZ/ChargeMonitor](https://github.com/CrashSystemZ/ChargeMonitor) 的汉化增强 fork，已开源为 [yuting-ou/MiaoDian](https://github.com/yuting-ou/MiaoDian)，通过本地 build.sh / 打包.sh 构建并以 GitHub Releases 分发（不走上游 Homebrew 渠道）。

## 目录结构

- `ChargeMonitor/` — 源码 git 仓库（Swift/SwiftUI，macOS 菜单栏应用）
- `build.sh` — **唯一构建入口**（汉化版本地构建，仅需 Command Line Tools，无需完整 Xcode）
- `AppIcon.icns` — 构建时复制进产物的应用图标
- `输出/妙电.app` — 构建产物目录（由 build.sh 重建，勿手工编辑）

## 构建与验证

```bash
bash build.sh          # 先跑单元测试，全过才编译打包
bash 测试/run_tests.sh # 单独跑测试（自制断言 harness，与主程序共用源文件，测的是真代码）
```

- 版本号单一来源：`ChargeMonitor/ChargeMonitor.xcodeproj/project.pbxproj` 的 `MARKETING_VERSION`
- 源文件由 build.sh 自动收集（`ChargeMonitor/ChargeMonitor/**/*.swift`），新增文件无需改脚本
- 单元测试是构建前置门：纯逻辑回归（估算/格式化/配置迁移/历史记录状态机判定）失败时构建直接中止
- 口径抽查（验证"醒着/含睡"两口径与标记覆盖率、队列触发条件，一条命令可复跑）：`bash 工具/口径抽查.sh`
- 卡片高度标定（列配平用的声明高必须由此回填，不许凭感觉填）：`bash 工具/离屏验收.sh cards`
- 能量红线（§1 不可谈判之一）用 `bash 工具/自身成本.sh 60` 复跑：并报"累计 CPU 时间"与"`sample` 在栈样本"两个口径，**禁止用 `top -l N` 当证据**（它把脉冲负载平均成 0.0%）；2026-09-23 实测 0.07%~0.23% 区间、无热点
- 内存基线（单点 RSS 不可跨条件比较；2026-09-24 我拿 30MB 与 80MB 两个不同条件的单点当版本回归，白起一轮疑点）：`bash 工具/内存基线.sh [app路径] [旧版dmg]`——冷启动、面板不开、t+0.5/+2min 定点采；同口径实测 v2.9.12 与 v2.9.13 均 79→70/71MB，本机正常区间约 70–82MB
- 测试基线（2026-09-24 @ v2.9.13）：本机 **1263** / `TZ=UTC` **1264** 全绿
- 发布线：**v2.9.13**（动画打磨：充电呼吸点收窄到 ±5%/2.0s，呼吸类动画按周期分档走 15fps；参数与档位规则搬进 `PanelMotion` 才可测）；队列余 E2（需用户配合）/ H4 / 每轮询成本拆解（触发条件见经验账本）
- 工具链与 SDK：SDK 27 起 SwiftUI 属性包装器（`@State` 等）是宏实现，而 CLT 27 工具链不带 SwiftUIMacros 插件——build.sh **不按路径名猜环境**，用 `@State` 探针实测当前工具链能用哪个 SDK 编 UI：能编用默认 SDK，否则回落到最新的可编 26.x SDK，全失败则报错给指引（2026-09-15 在 macOS 27.0 + CLT 27 实测：默认 27 失败、回落 26.5 成功；装完整 Xcode 后自动走默认）。测试面不钉旧 SDK，用默认 SDK 编译并回显版本，故逻辑层一直吃本机最新 SDK 的信号
- 编译信号边界：CI 在测试面之外另跑全量源码 Swift 6 审计（含 UI 层），保证「CI 绿 = 可构建」；但 CI runner 是 macos-26（GitHub 尚无 macos-27 镜像，2026-09-15 实测其 README 404），**UI 层在 SDK 27 下的编译暂无自动信号**——macos-27 镜像可用后把 `.github/workflows/tests.yml` 的 `runs-on` 换过去补上

## 注意事项

- README 中的 Homebrew/GitHub Releases 安装方式属于上游英文原版，本地汉化版以 build.sh 构建为准
- 面板控制行没有"检查更新"入口（上游时代已移除）；对外分发统一走本仓库的 GitHub Releases
- 失败诊断日志：`log stream --predicate 'subsystem == "fun.crashsystem.ChargeMonitor"'`
- 目标模式（自主迭代循环）：宪法是根目录 `目标模式·提示词v6.md`（本地不入库；当夜会自修订，**当前版本号只写在它首行**，本文件不抄以免漂移），细则见 `目标模式作业书.md`；`迭代报告.md`（每轮流水 + 晨间摘要）与 `经验账本.md`（教训/无恙清单/直觉校准）是其配套本地文件，均 gitignored
