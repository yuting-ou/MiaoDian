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
- **clock 接线守卫**：门面必须把**同一个** clock 传给全部 7 个域（`run_tests.sh` 按 `persistence: persistence.*clock: clock` 计 7 次核对）。行为断言说服不了这件事——少传一个域，那个域继续吃真实 `Date()`，测试却在推进假钟，断言就按运气红绿。渗漏一个域恰恰是"测试看运气绿"的标准成因。
- **源文件级守卫有元守卫**：`run_tests.sh` 里那些按源码文本核对的守卫（UI/ 不进测试编译面，只能这么查）全部收在 `run_source_guards()` 里，脚本会把它**对一份注入变异的源码副本再跑一次**——变异必须让它红，红不了就是"守卫没在工作"，直接构建失败。这条是给"假绿"上的保险：本项目踩过两次（v2.9.10 以为兑现了出口断言、v2.9.16 注释顶替真调用），守卫自己不吭声时"全绿"什么都不证明。**新增源文件级守卫请写进 `run_source_guards()` 内**，否则不受元守卫保护
- 口径抽查（验证"醒着/含睡"两口径与标记覆盖率、队列触发条件，一条命令可复跑）：`bash 工具/口径抽查.sh`
- 滚动/渲染成本（**每格**主线程忙时分布、静置期 layout 级联分桶、发布计数、④ 起停序列的"起手/停手/中间"三堆样本）：`bash 工具/滚动成本.sh [静置秒] [步数]`；只读对照模式 `bash 工具/滚动成本.sh idle yes|no`。**只有同一进程内的同表对比才算数**——已两次实测到跨运行 3 倍的静置占空差（跨零点数据变化、前一窗口未静默），单点数字不要写进结论；**改步数=改条件**（12 格与 40 格跨过的数据发布周期数不同，v2.9.16 轮里我拿 12 格的消融比 40 格的基线，得出过一条假结论）
- 该量具 2026-09-27 凌晨实测的基线（后续对比以此为锚，别再重新猜）：**一次数据 tick 的失效级联 ≈ 320ms 主线程 / ~900 轮 layout**（静置 10s 里 5 簇 → 占空 17~19%，跨 4 次运行都在这条带上）。④ 起停序列按"本窗**或上一窗**有没有发布到达"分堆（级联会跨窗，只按本窗到达分堆会把带尾巴的窗算进"无发布"那堆）：**停手窗受污染 265.4ms（n=7）／不受污染 59.7ms（n=5）**、起手格 40.7ms、连滚中的格 p50 10.5ms ⇒ **"停手卡一下"基本就是那一次级联的账，翻转自己 ~30ms 量级**（等长且不受污染的对照窗只剩 n=1/23.2ms——发布节奏 1~2s、窗口 0.7s，几乎每扇窗都离一次级联不到一窗，所以这个"翻转自己值多少"只给上界不给点值）。消融"停手干脆不补发快照"把停手窗从 179.7ms 压到 77.7ms，可**等长对照窗 137.0→137.3ms（原地不动）**、级联簇同带（A 跑 219~335ms/626~979 轮 vs HEAD 312~341ms/835~989 轮）——**看着像"挪账不是省钱"，但总量是否真没减要先比两轮的静置占空，尚未做**。因此本轮不下"取消补发"的结论，该打的是一次级联本身（#24）
- 已证伪、别再重测：探针装卸（整段不挂探针，静置级联仍 657~1037 轮）、**"逐行淡变不是原因"——那条措辞是错的**（真相见下条：单独撤一族无效，两族一起撤才塌）、宿主 `layout()` 整树 DFS、"覆盖 layout() 本身贵"（多面板实例污染）、重排弹簧自持循环（作为每拍级联的解）、**"翻转本身很贵"**（无发布的停手窗 59~67ms，与翻转无关的对照窗同量级）、**masonry 双轮量测／总高缓存**（一次发布 `size/place` 只有 1/1，量测次数不随轮数放大——别去做高度缓存）
- 轮17 定因（同进程配对 A/B，`steps=40` 固定，原始样本见 `PROGRESS.md`/`BLOCKED.md`）：一次数据发布的 ~830 轮 layout **不是在算布局，而是被在飞的隐式动画逐帧请求**（栈顶 `NSHostingView.setRoot ← requestUpdate(after:) ← Transaction.addAnimationListener`）。**剂量关系**：全开 762~837 轮/次｜只撤信息行值淡变 ~800 轮（几乎不动）｜只撤两条迷你曲线副标题 ~500 轮｜**两族一起撤 → 2 轮**。修法＝`BatteryInfoItem.animatesOnChange`（6 条每拍重算的读数给 false）+ 曲线副标题删淡变；配对实测**每级联 830 轮/358ms → 2 轮/82ms**（−99.7%/−79%），发布次数与 masonry size/place 两侧完全相同（17 次／13/13）⇒ 不是挪账。守卫在 `run_tests.sh`（淡变守卫两条按源文件核对 + "登记表条数"那条已换成测试里的**完备性行为断言**：穷尽夹具把 formatter 全部 19 个标签逼出来，与淡变登记逐行比对——比数源码条数强，因为新增行会改变标签全集而必须显式登记；四条变异含"注释顶替真调用"全红）。**未达线的一维**：窗口总轮数只降 25~27%，因为约 3200 轮/12s 落在入场段（`CascadeIn` 延迟弹簧，只花"开面板那一下"的钱）。
- **新头号（#25，轮18 已把账量出来，改法未定）**：面板开着不动也在重排——12s 窗口 ~1320 轮，多数落在两次发布之间。
  配对 A/B（同进程条件、严格交替 5 对、979pt 全卡片）：入场 `CascadeIn` 弹簧 + 把手 frame 弹簧 + 卡片重排弹簧三处照旧 = **中位 1316 轮/356ms**；
  同三站点给 `.animation(nil, value:)` = **中位 5 轮/105ms**（该侧双峰：4/5/5 与 617/637，最差一跑仍 −52%）。
  **两条猜测已排除**：亚像素抖动回写（0.05/0.5pt 容差各测，原地不动）、"spring 永不收尾所以换 easeOut"（三处全换 easeOut 还剩 817~845 轮）。
  剩下的候选改法＝让这三处只在真会被看见时挂动画（一次性 settled/repacking 标记，非常驻定时器），**观感不许退**（拖拽跟手与滑位是既有体验）。
  另：16:41 前后读到的 97~99% 占空此后 8 连跑都没复现（充电=0 之后就没回来）——同一类账的极端相位，量具读数前先连跑两三次确认机器在好状态。
- 卡片高度标定（列配平用的声明高必须由此回填，不许凭感觉填；登记表在 `PanelCardHeights`，含体检/洞察/今日用电三张）：`bash 工具/离屏验收.sh cards`
- 能量红线（§1 不可谈判之一）用 `bash 工具/自身成本.sh 60` 复跑：并报"累计 CPU 时间"与"`sample` 在栈样本"两个口径，**禁止用 `top -l N` 当证据**（它把脉冲负载平均成 0.0%）；2026-09-23 实测 0.07%~0.23% 区间、无热点
- 内存基线（单点 RSS 不可跨条件比较；2026-09-24 我拿 30MB 与 80MB 两个不同条件的单点当版本回归，白起一轮疑点）：`bash 工具/内存基线.sh [app路径] [旧版dmg]`——冷启动、面板不开、t+0.5/+2min 定点采；同口径实测 v2.9.12 与 v2.9.13 均 79→70/71MB，本机正常区间约 70–82MB
- 测试基线（2026-10-03 v2.9.20）：本机 **1526** / `TZ=UTC` **1527** 全绿零警告（1502 之上 +24 条边沿 evaluator 断言；UTC 1527 为实测；门面顺序断言与 clock 接线守卫见架构节；新增源文件级守卫一律带元守卫变异验证）。轮17 改动已提交（`8647c35`，v2.9.17）；v2.9.18 架构轮已提交（`b7ed487`）；v2.9.19 保养拆分 + 回写修复已发布；v2.9.20 边沿族拆分 + 测试门修复已发布
- **测试编译面排除规则（2026-10-04 修，工具链三坑 + 两条守卫）**：`run_tests.sh` 排①`UI/` 全目录（白名单 `UI/BatteryInfoFormatter.swift`）②手写**视图宿主名单**（`Core/ChargeCurveWindowController.swift`、`Core/MenuBarPanelController.swift`——都用 `NSHostingView` 承载被排掉的 UI/ 类型，漏排会让 swiftc 报 `cannot find type` 把门堵死）③**宏宿主正则**。新增 `run_exclusion_audit()` 按两种形态自检：① 用 `NSHostingView(` 却不在名单里；② 非 UI 文件在**代码**里引用 UI/ 顶层声明的符号（剔注释、扣白名单 `BatteryInfoFormatter.swift`、扣已排除文件自身）。形态② 已变异验证：往 `EnergyAggregation.swift` 注入 `_ = SparkAreaChart.self` → 精确点名变红。
  - **本机工具链坑 + 一条方法论（2026-10-04 实测，写在这里防止改回去）**：**PATH 里的 grep 是 WorkBuddy 注入的 toybox 0.8.13 shim**（`/Applications/WorkBuddy.app/.../brokered-bin/grep`），**不认 `\b`**——同输入 `'@State\b'` 下 `/usr/bin/grep` 匹配、shim 不匹配。宏判据边界一律写 `([[:space:]]|$)`；写成 `\b` 会让整条判据**恒假** ⇒ 宏宿主静默漏排。**这条是本轮唯一一个已坐实的工具链坑。**
  - **方法论（比结论更值钱）**：本轮我一度把"判据恒空"归因为"toybox grep 不接受多文件参数"，并把它写进了 AGENTS——**复测证明那是误判**（`grep -h 'func ' a.swift b.swift` toybox 与 `/usr/bin/grep` 同为 10，多文件参数完全正常）。真因是管道里文件列表为空。**所以：判据恒空时，先打印文件数与命中数，再动工具；不要把一次环境观察写成平台规律。** 形态①/② 已各配自检（`N_LINES < 100` 行数下限、`UI_SYMS` 空集即红），这类"恒空不可能静默"的自检比再写十条守卫更根本。
  - `@ObservedObject`/`@Bindable` **不是宏**（27.0 SDK swiftinterface 里 `macro ObservedObject` 计数为 0），留在正则里无害但别当"补漏"讲；真正的漏排原因是坑①。反过来别把 `@Observable` 拿掉——它是 7 个 recorder 的宿主标记。
  - 宏判据必须**剔注释行**：`Core/AppServices.swift` 注释里写着"不再挂在 App 结构的 `@StateObject` 上"，不剔会把这个纯逻辑文件误排除（误排除不报错、只是悄悄少一批断言）。修后宏宿主从 2 个降到 1 个（只剩 `SettingsView`），**覆盖净增**。
  - 排除任何文件前先确认里面没有可测逻辑——UI 层 5046 行（占生产代码 29%）目前零测试信号，是本项目最大的结构性风险。
- 发布线：**v2.9.20**（拆分 1b 第二刀：充满/低电/高温三条边沿提醒判定抽进 `Services/ThresholdAlertEvaluators.swift`，Controller 转发层删除（18 处断言改直调 evaluator）；**测试门两处假绿洞修复**：①编译失败原先不拦——swiftc 失败后旧二进制照跑/127 被降级分支接住照样 exit 0，现在清旧二进制+查退出码必红；②"零警告"从来只是口号——账本 2026-09-05 的警告门规则从未落进脚本，轮20 起 3 条 var 警告被历轮记成零警告，现在编译警告门+4 条警告修掉；边沿出口守卫带专属元守卫探针；详见 `CHANGELOG.md`）
  - v2.9.19（拆分 1b 第一刀：`evaluateChargeCare` 状态判定抽进纯 evaluator `ChargeCareAlertEvaluator`；补拆分引入的状态回写遗漏 `didNotifyChargeCare`——不补就是"提醒过一次就再也提醒不了"；漏接线必红守卫进 `run_source_guards()` 并带元守卫专属变异；**GitHub Release 恢复发版，DMG 同时携带从未单独发版的 v2.9.18 架构轮改动**）
  - v2.9.18（架构轮：历史采集拆成门面 + 7 个域 recorder、时间序列搬出 UserDefaults 到一键一文件、面板布局判定抽出、守卫补元守卫、CI 补量具编译审计；已提交 `b7ed487`，未单独发版）
  - v2.9.17（一次数据发布的 ~830 轮布局级联定因并砍到 2 轮：`BatteryInfoItem.animatesOnChange` + 曲线副标题删淡变；面板字阶收敛成唯一来源；补空态）
  - v2.9.16（洞察内容与卡片资格同出一个函数 `HabitInsights`：参数表不再被抄第二遍，来源一律必填、注入时钟一路转到底；设置窗口补观察 monitor/alertController；六来源每条有夹具与变异；单一出口守卫只扫生产源码）
  - v2.9.15（滚动静默阈值按「翻转代价」重定为 400ms 并附同表 A/B；充电通道三处墙钟动画滚动期停帧，警示通道两处按规矩豁免，守卫是源文件级登记表 5/3）
  - v2.9.14（卡片高度登记表 `PanelCardHeights`：体检卡与洞察卡按实测与真实折行数给高，洞察上限两侧共用一个常量并有源文件级门）；队列余 E2（需用户配合）/ H4 / 每轮询成本拆解（触发条件见经验账本）
- 工具链与 SDK：SDK 27 起 SwiftUI 属性包装器（`@State` 等）是宏实现，而 CLT 27 工具链不带 SwiftUIMacros 插件——build.sh **不按路径名猜环境**，用 `@State` 探针实测当前工具链能用哪个 SDK 编 UI：能编用默认 SDK，否则回落到最新的可编 26.x SDK，全失败则报错给指引（2026-09-15 在 macOS 27.0 + CLT 27 实测：默认 27 失败、回落 26.5 成功；装完整 Xcode 后自动走默认）。测试面不钉旧 SDK，用默认 SDK 编译并回显版本，故逻辑层一直吃本机最新 SDK 的信号
- 已知边界：极端时区（`TZ=Pacific/Midway`、`Pacific/Kiritimati`）下有 4 条既有断言会红（v2.9.12 的驻留倒计时夹具与月份键对照），HEAD 同样红——本机/UTC/Berlin 三条链路全绿是 declared 门禁，扩到全时区前别把它当已修
- 编译信号边界：CI 在测试面之外另跑全量源码 Swift 6 审计（含 UI 层），保证「CI 绿 = 可构建」；UI 层在 SDK 27 下的编译信号由 2026-10-04 新增的 `sdk27-audit` 实验门补上（`.github/workflows/tests.yml`：`xcode-27` 镜像 = macOS 27 底座 + Xcode 27.0，preview，`continue-on-error` 不挡发布门）——镜像转正后删掉 `continue-on-error` 并把主门 `runs-on` 收敛过去。开发机仍是 CLT 27（缺 SwiftUIMacros 插件），UI 这一路本地只能编 26.5（build.sh 探针自动选，装完整 Xcode 后自动走默认 SDK，脚本零改动）

## 架构（v2.9.18 拆分后）

- **历史采集 = 门面 + 7 个域 recorder**。`BatteryHistoryRecorder` 现在只剩转发、编排与持久化静态方法（约 250 行，原先 1435 行）；各域自持状态、自带入口：
  `ChargeSessionRecorder`／`ChargerProfileRecorder`／`DailyUsageRecorder`／`SleepDrainRecorder`／`SocSampleRecorder`／`PowerEventRecorder`／`HealthTrendRecorder`（均在 `Services/`）。
  门面**对外 23 个成员名逐字未变**，视图/设置/提醒那 8 个调用方基本不用改。域之间只走显式注入：会话域的身份键由门面每拍传入；睡眠域持有每日用电域（睡眠时长要记进当天用电行）；健康域持有事件域与 monitor（换电池要往时间线记一笔）。
  **`process(_:)` 的调用顺序与拆分前逐字一致，其中两处顺序有理由**（① 先认充电器再开会会话，否则新会话身份键丢；② 睡眠结算排在建好当天日行之后，否则跨午夜那一觉被"缺行跳过"整夜吞掉）。原先这两条只有注释钉着——调乱了 1473 项测试一项都不会红。现有「门面顺序」那组断言逐条钉住（`测试/main.swift`：身份键按"先无名后有名"摆位，**不能帧1 就带名**，否则会话域的 backfill 会把反序的账吸收掉、断言照绿顺序照错；睡眠结算按跨午夜摆位、断言写在**唤醒日**那行）。两条各做过变异验证（把对应步骤挪位 → 红）。
  **`process`/`handleWillSleep`/`handleDidWake` 是 internal 不是 private**：只为让那组断言能直接驱动，生产入口只有 init 里那一处订阅，不许长出第二条调用路径。这些断言**全程零 await**——门面真挂着 `BatteryMonitor` 的 2 秒轮询订阅，一旦让出主线程，真快照会插进来把确定性变成看运气；后人往这组测试里加 `await` 会静默破坏它。
  `DailyUsageRecorder.dayKey` 提成 internal：那组断言要按**真实日键**摆跨午夜的位，测试自己抄一份 `yyyy-MMdd` 就是第二个真源。
- **时间是注入的**：`HistoryClock`（`Services/HistoryClock.swift`），25 处 `Date()`/`Calendar.current` 全部收口。测试用 `MutableHistoryClock` 推进假钟，跨午夜结算、24 小时窗口这类状态机才能确定性驱动。
- **门面 objectWillChange 转发经恒等式验证**：7 个子域的 `objectWillChange` 由门面**原样转发**（1:1，不合并、不放大）。这个性质是**恒等式**而非统计量——`工具/滚动成本.swift` 的 `idleOnly` 末尾在同一次运行内两侧对数（子域合计 vs 门面转发），连采三次一致、差恒 0（15=15／15=15／15=15）。**这条不走"A/B 两棵树"的规矩**：等式不是分布，"单点不写进结论"管的是后者。早先我误拿 idle 模式的单次占空读数当 A/B（4.6%/363 轮 vs HEAD 4.4%/355 轮）——**那组读数已作废**：idle 模式本就没有普查段，且 n=1 不达"同表 ≥5 对"门槛。
- **文件主档 schema 版本化：判定过度设计，推迟**（2026-10-01 决策）。一个全局版本整数**表达不了真实迁移形状**——真要改字段，改的是某个键的 payload，迁移发生在域的 `loadFromDisk()` 时刻而非启动时刻，目录级整数无法表达"键 A 已迁、键 B 未迁"，到期仍要拆成 per-key。仓库早有更轻且合先例的做法可抄：`AppConfiguration.swift` 的「旧档缺字段 → `decodeIfPresent` → 默认/一次性种子 Bool」，判据长在 payload 里，零新文件、零启动写、天然随 byteStore 改道。**触发条件**：真有一次 schema 变更排队时再做，且必须作为 byteStore 的一个普通键（`set(_:forKey:)`），不另起 IO——否则绕开 `MIAODIAN_HISTORY_DIR` 隔离，会重演 v2.9.15 那条"另一条硬编码路径把用户真数据写花"。
  - 顺带暴露的真缺口：`HistoryPersistence.load` 把**旧档缺字段**和**真损坏**一律记成 `history-corrupt-<key>`——在 `decodeIfPresent` 修好缺键之前，这一条会误报旧档。待做。
- **历史主档 = 一键一文件**（`HistoryStore.swift`），落在 `~/Library/Application Support/ChargeMonitor/history/<键>.plist`，不再是和配置挤在一起的 UserDefaults plist。迁移语义三条（都有测试）：抄旧字节、**不删旧键**（回滚旧版本仍可读）、幂等；`removeObject` 会连带清旧键，否则"文件不在→迁回旧键"会把刚删的数据复活。UserDefaults 仍留配置与两个小标量（电池序列号/更换时刻）。
  - 量具必须隔离：`MIAODIAN_HISTORY_DIR`（空串=不落盘）。**只设 `MIAODIAN_BACKUP_DIR` 时历史目录会自动跟到它下面**——这是兜底，防"改了备份路径却把用户真历史写花"（v2.9.15 同型事故）。`工具/滚动成本.sh`、`工具/离屏验收.sh` 两个变量都显式设了。
- **面板布局判定进了 `Utilities/PanelLayoutModel.swift`**（`PanelColumnPlan`／`PanelDragMachine`／`PanelLayoutEdit`／`PanelLayoutRouting`）。**只搬判定、不搬状态**：`@State` 槽位一个没动，所以每次写入触发的失效节点集合与写入顺序逐字未变——#24/#25 的账记在这条链上，动状态归属前先看该文件的注释。
- **电池提醒控制器（`Services/BatteryAlertController.swift`）的拆分：1a 缝纫已提交 3/4（`dcb839f` 里程碑写回脱离全局偶合、`78a7d62` defaults 提为 init 注入、`46a3d50` 时间源收进可注入时钟），1b 已收口两刀（v2.9.19 第一刀：`evaluateChargeCare` 判定抽进 `Services/ChargeCareAlertEvaluator.swift`；v2.9.20 第二刀：充满/低电/高温三条边沿提醒抽进 `Services/ThresholdAlertEvaluators.swift`，轮20 的五个转发纯函数删除、18 处断言改直调 evaluator——过渡形状清掉）。Controller 只留外壳（读配置成值→驱动判定→回写→shouldSend 才 send→成功才置位）；拆分引入的 `didNotifyChargeCare` 回写遗漏已补——教训是"抽状态机时三个状态要逐个对账回写"，守卫已让漏接线必红）**。它是全项目最大单文件（约 889 行）且**本体在当前 harness 结构上测不了**——见下一节。1a 的原始第一刀（`dcb839f`）：里程碑写回从 `ConfigurationManager.shared` 裸写改为走 init 注入的同一实例（原先类里根本没这个成员，依赖靠全局偶合，且注释自说"持有 configurationManager 时可 update"——那条路径从来不存在）。
- **⚠️ `BatteryAlertController` 的 UN 外壳在本 harness 不可测，且原因不是"没写测试"**：`run_tests.sh` 编译出的是**裸二进制**（无 Info.plist、无 bundle id、无 codesign），而 `BatteryAlertController.init` 第一件事就是 `UNUserNotificationCenter.current().delegate = self` + `registerNotificationCategories()`。本项目自己在 `工具/滚动成本.sh` 的注释里实测过：**裸二进制里 `UNUserNotificationCenter` 要求有效 bundle 上下文，直接抛 NSException**。因此在测试面里构造 controller = 一构造就把 1526 项全带走。
  - **推论一**：任何"先给 controller 补 characterization 测试再拆"的计划在当前 harness **跑不起来**。顺序必须是 **1a 缝纫（把 defaults / 时钟 / 配置写回全部改成可注入）→ 1b 抽出 UN 不接触的 evaluator → 1c 才谈得上测判定**。而 1a 本身是**没有测试门保护的生产改造**——这是整个方案最脆的一环，落地前先想清楚怎么在不引入回归的前提做。
  - **推论二**：**别为了"可测"给测试面造 .app 壳**。壳要动全体测试的 harness 去换一个"controller 可构造"，而 evaluator 脱离 UN 后本来就可测——壳是白担风险。项目里已有现成反例：`工具/滚动成本.sh`／`工具/离屏验收.sh` 各自造临时 .app 是因为它们**必须**真的发通知，单测不需要。
  - **推论三**：判定侧真正的不可测面只有 UN 那 8 处触碰点（delegate 接管 91 / `requestAuthorization` 157 / `getNotificationSettings` 167 / `add(request)` 844 / `setNotificationCategories` 859 / 两个 `userNotificationCenter` delegate 回调 895·902 / `handleNotificationResponse` 909）。**9 条 `evaluate*`（原 12 条，充满/低电/高温已抽出）+ 8 个边沿标志 + 温度环形缓存 + 保养暂停边沿一个 UN 都不碰**，只依赖 `configuration` / `lastSnapshot` / `defaults` / `historyRecorder` / `monitor` / `send()` 六个面——这才是该搬进 evaluator 的东西。剩余 9 条里逻辑最密的是耗电异常/低电预判对（nil 估算的语义分叉）与温度骤升（环形缓存）。
  - **三条最易在拆分中被静默弄丢的不变量**（它们长得最像"可以顺手简化"的代码）：① 保养并存标记的**拔电重置**不许被保养提醒开关挡住——`evaluateChargeCare` 里 `didObserveSystemHoldAtLine` 的推进刻意先于 `guard …contains(.chargeCareReminder)`；② 健康里程碑的**基准在开关关闭时照常抬**（`evaluateHealthMilestone` 的 `guard alertEnabled` 分支里仍 `defaults.set(health, …)`）；③ 周/月报**无内容也记账**（`checkWeeklyDigest`/`checkMonthlyDigest` 的 `guard !body.isEmpty else` 分支仍写 `Date()`），否则 `digestSendAllowed` 每轮空转。

## 注意事项

- README 中的 Homebrew/GitHub Releases 安装方式属于上游英文原版，本地汉化版以 build.sh 构建为准
- 面板控制行没有"检查更新"入口（上游时代已移除）；对外分发统一走本仓库的 GitHub Releases
- 失败诊断日志：`log stream --predicate 'subsystem == "fun.crashsystem.ChargeMonitor"'`
- 目标模式（自主迭代循环）：宪法是根目录 `目标模式·提示词v6.md`（本地不入库；当夜会自修订，**当前版本号只写在它首行**，本文件不抄以免漂移），细则见 `目标模式作业书.md`；`迭代报告.md`（每轮流水 + 晨间摘要）与 `经验账本.md`（教训/无恙清单/直觉校准）是其配套本地文件，均 gitignored
