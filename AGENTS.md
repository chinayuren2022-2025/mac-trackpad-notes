# Trackpad Studio 手写版：给 AI 助手的说明

这是一个 macOS 原生应用（Swift / AppKit，无第三方依赖）：用被动电容笔在 MacBook 内置触控板上手写，触控板位置按绝对坐标映射到画布。基于开源项目 Trackpad Studio（MIT 许可证）修改。

**最常见的任务**：让防误触、笔尖识别、双指拖动适配新用户的手和笔。所有阈值都是用真实录制数据校准的。**不要凭感觉改数字**，按下面的“校准流程”做。

## 构建与运行

需要 Apple 芯片 Mac、macOS 13+、Xcode Command Line Tools（`xcode-select --install`）。

```bash
scripts/deploy.sh          # 编译 release 版，安装到 ~/Applications/TrackpadStudio-Handwriting.app
scripts/make-dmg.sh 1.2    # 生成 dist/TrackpadStudio-Handwriting-1.2.dmg，用于分发
```

覆盖安装前，先让用户保存并退出正在运行的应用（⌘Q）。运行中替换二进制可能导致崩溃，未保存的笔迹会丢失。

防误触依赖私有框架 MultitouchSupport 提供的触点形状，需要用户在“系统设置 → 隐私与安全性 → 输入监控”里授权，授权后重启应用。应用只有 ad-hoc 签名，每次重新编译后签名都会变，可能要重新授权。

## 代码地图（`Sources/TrackpadStudio/`）

| 文件 | 内容 |
|---|---|
| `PalmRejection.swift` | **防误触核心**，纯逻辑、可测试。`classify`（笔 / 非笔）、`isFingerShaped`、`isClearlyPalm`、`PalmRejector.process`（从所有触点中选出唯一能落笔的触点：落笔后锁定、被拒触点抬起前不再成为笔、左右手位置规则） |
| `BoardTab.swift` | 画布视图。`handlePalmFiltered`（输入入口，接入 PalmRejector）、`handleTwoFingerGesture`（防误触开启时的双指拖动/缩放：开始条件、丢帧容忍、手指重新识别）、`contactShapes`（系统触点与私有触点按位置匹配）、渲染缓存（`refreshCanvasCache`，GPU 合成）、橡皮、`--bench` 基准测试 |
| `BoardModel.swift` | 画布元素、撤销历史（快照）、橡皮几何判定 |
| `MultitouchBridge.swift` + `CMultitouchShim/` | 通过 dlopen 读取私有 MultitouchSupport 帧：size、majorAxis、minorAxis（单位 mm） |
| `TouchRecorder.swift` | 菜单“录制触点数据”：把每帧系统触点和私有触点写成 JSONL |
| `TrackpadCore.swift` | 系统触点（NSTouch）采集视图、坐标换算 |
| `ConnectorCore.swift` | **无边记连接器的纯逻辑**：把原始触点帧转成鼠标的按下、拖动、抬起。规则与画布相同，另外处理：新笔尖确认一帧再按下（手指落下的第一帧可能像笔尖）；同一笔尖短暂淡出（最长 120 ms）且回来的位置与速度吻合时算作同一笔；双指手势期间放行系统的滚动和缩放 |
| `FreeformConnector.swift` | 连接器的系统部分：用事件监听屏蔽触控板原有的指针和点击（仅在无边记位于前台时），模拟鼠标事件，定位无边记窗口，显示书写区域虚线框和菜单栏状态，⌃⌥⌘F 切换书写/鼠标模式。需要“辅助功能”权限 |
| `AppShell.swift` | 菜单与命令行模式（`--snapshot DIR`、`--bench 录制文件 份数`）；菜单栏图标与全局快捷键 ⌃⌥N |
| `NotesWindow.swift` | 主窗口与小窗 `FloatingNotePanel`（非激活浮动面板，`.canJoinAllSpaces` + `.fullScreenAuxiliary`，能浮在其他应用的全屏界面上）。只有一个画布实例，在两个窗口之间移动 |
| `GlobalHotKey.swift` | Carbon `RegisterEventHotKey` 全局快捷键，不需要任何权限 |

## 当前阈值（均按原作者的手和笔校准）

| 规则 | 位置 | 当前值 | 原作者数据 |
|---|---|---|---|
| 笔尖 | `classify` | size ≤ 0.5 且 长轴 ≤ `penMaxMajor`（默认 8.0 mm，用户可按 `-`/`=` 调） | 笔尖 size 0.30–0.35，长轴 6.2–7.4 mm |
| 指腹 | `isFingerShaped` | size 0.45–1.3，长轴 ≤ 11 mm，长短轴比 ≤ 1.3 | 双指拖动：size 0.43–1.1，长轴 8.1–9.9，比值 p95 1.21；短轴会低到约 7 mm，所以不作为判据 |
| 明确是手掌 | `isClearlyPalm` | 长轴 > 12 mm 或 size > 1.5 | 手掌长轴 ≥ 9.3 mm，最大约 40；掌根碎片 size 可小到 0.1 |
| 双指手势开始 | `handleTwoFingerGesture` | 两个触点都指腹形状且 y > 0.06 | 双指 y ≥ 0.17；掌根在 0.01–0.05 |
| 双指丢帧容忍 | 同上 | 80 ms | — |

“手指和原作者不一样”通常意味着：`isFingerShaped` 的范围要按新用户的数据调整（比如手指更大：size、长轴更大；手指更细：长短轴比更大）。

## 校准流程（必须按顺序）

1. **让用户录制。** 在应用菜单“防误触 → 录制触点数据”里，每项录 20 秒。至少录 ①只用笔、②只放手掌、④只用手指、⑤双指拖动缩放；最好再录 ③正常握笔书写。要调哪个问题，就让用户专门录下出问题的场景。文件保存在 `~/Library/Application Support/TrackpadStudio-Handwriting/touchlog/`，文件名前缀对应录制项目。
2. **分析。** 运行 `python3 scripts/analyze_touchlog.py`，查看各录制的 size、长轴、短轴、长短轴比、y 的分位数，以及当前规则的通过率。目标：
   - 1-pen：笔尖识别率约 100%；
   - 2-palm：笔尖识别率 0%，“accepted as two-finger gesture” 0%；
   - 5-twofinger：“accepted as two-finger gesture” 尽量接近 100%；
   - 笔尖、指腹、手掌的分布之间要留出余量，不要让阈值正好卡在某一类的边缘。
   - 已知例外：`calibration/reference/3-write-2026-09-23T12-00-54Z.jsonl` 在 t≈8.3 s 处有一次约 0.4 秒的**真实**双指拖动（两个触点在触控板中部一起移动），所以它的“accepted as two-finger gesture”约 4.7% 是正确结果，不是误判。
3. **修改 Swift 阈值**，同步修改 `scripts/analyze_touchlog.py` 顶部的镜像常量。
4. **验证，不要跳过：**
   - 用新用户的录制，外加 `calibration/reference/`（原作者的录制）重新运行分析，确认手掌录制的笔尖识别率和双指误触发都仍是 0；
   - 回放：`swiftc -parse-as-library scripts/replay_touchlog.swift Sources/TrackpadStudio/{TrackpadCore,PalmRejection}.swift -o /tmp/replay && /tmp/replay <录制文件...>`（加 `--finger` 模拟手指书写模式），输出落笔帧数、笔画数，以及落在明确手掌形状上的落笔（应为 0）；
   - 单元测试（下一节）全部通过，改阈值后相应更新测试里的样例形状。
5. **部署**，让用户实际试用，再把新的问题场景录下来，重复上面的流程。

## 测试

```bash
S=Sources/TrackpadStudio
swiftc -parse-as-library scripts/test_palm.swift $S/{TrackpadCore,PalmRejection,PenAim,PressureGate}.swift -o /tmp/tp && /tmp/tp
swiftc -parse-as-library scripts/test_eraser.swift $S/{BoardModel,BoardArchive,InkRenderer,TrackpadCore,PalmRejection}.swift -o /tmp/te && /tmp/te
swiftc -parse-as-library scripts/test_archive.swift $S/{BoardModel,BoardArchive,InkRenderer}.swift -o /tmp/ta && /tmp/ta /tmp/archive-check.json
swiftc -parse-as-library scripts/test_notes.swift $S/{BoardModel,BoardArchive,InkRenderer,NoteLibrary}.swift -o /tmp/tn && /tmp/tn
swiftc -parse-as-library scripts/test_connector.swift $S/TrackpadCore.swift $S/PalmRejection.swift $S/ConnectorCore.swift -o /tmp/tc && /tmp/tc && /tmp/tc calibration/reference/*.jsonl
swift build --package-path . -c release
```

`test_connector` 不带参数时运行合成用例；带录制文件时，把原始帧回放给连接器，检查按下和抬起是否成对，并统计笔画数和双指手势帧数（手掌、单指、双指录制中的笔画数都应为 0）。

落笔预测回放（用真实书写录制评估 PenAim：先预测再学习，输出误差中位数和落在标记圈内的比例）：

```bash
swiftc -parse-as-library scripts/replay_penaim.swift $S/{TrackpadCore,PalmRejection,PenAim}.swift -o /tmp/aim && /tmp/aim calibration/reference/3-write-*.jsonl
```

界面截图自检（使用临时笔记库，不碰真实笔记；输出 window.png、window-writing.png（书写模式）、note.pdf、note.png 后自动退出）：

```bash
"$(swift build --package-path . -c release --show-bin-path)/TrackpadStudio" --snapshot /tmp/snap
```

性能基准（用真实笔迹铺满画布，测每帧耗时；同样使用临时笔记库）：

```bash
"$(swift build --package-path . -c release --show-bin-path)/TrackpadStudio" --bench calibration/reference/1-pen-2026-09-23T07-11-52Z.jsonl 10
```

书写时每帧应远低于 8.3 ms（120 Hz）。

## 注意

- 被动电容笔没有压力信号，线宽固定为 2，这是有意的设计。
- 录制文件是 JSONL：`mt` 行是私有触点（fid、st 状态、x、y 为 0–1 且 y 向上、size、maj、min 单位 mm、den 密度），`ns` 行是系统触点（id、x、y、resting）以及当时的防误触判定。
- 原作者的判定依据和实测数据，记在 `PalmRejection.swift` 和 `BoardTab.swift` 的注释里。
