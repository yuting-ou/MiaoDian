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

## 注意事项

- README 中的 Homebrew/GitHub Releases 安装方式属于上游英文原版，本地汉化版以 build.sh 构建为准
- 面板控制行没有"检查更新"入口（上游时代已移除）；对外分发统一走本仓库的 GitHub Releases
- 失败诊断日志：`log stream --predicate 'subsystem == "fun.crashsystem.ChargeMonitor"'`
