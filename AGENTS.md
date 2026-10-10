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
| `PadCalibration.swift` | 摄像头画面 ↔ 触控板坐标的单应性（`Homography.fit` 加权最小二乘）。从手动拖的四角出发（每角权重 4），之后每次落笔把“跟踪器看到的像素 ↔ 触点位置”作为一对加进来重拟合；满 20 对后，偏离 0.08 以上的不学，连续 8 次偏离算“对不准”（手机动过） |
| `TipTracker.swift` | 笔尖外观跟踪：落笔帧里沿笔身截一条模板（笔尖后 16 px 到笔身方向 70 px、两侧各 28 px，方向由标定 + 左右手算出，不从画面猜；留最近 3 个），在上次位置 ±80 px 内做半分辨率归一化互相关（vImage 卷积 + 积分图）；分数 < 0.6 不算，< 0.8 且离上次超过 40 px ×（1 + 连续丢失次数）算跳错。**不要用以笔尖为中心的方块**：方块大半是触控板，笔尖在玻璃上的倒影也在里面，悬空时会跟着倒影跑。`HoverCursor`：落笔时学习“光标 − 落点”的固定偏差（主要是视差：抬起的笔尖看起来比正下方更远离摄像头）并扣掉；笔离开触控板 0.3–0.7 s 后渐渐把光标沿笔杆往前推 `reach` 毫米（笔杆延长线和触控板的交点，而不是笔尖正下方；方向由左右手定，长度从“悬空 ≥ 1 s 后落笔”时落点比 0.15–0.4 s 前的位置往前多少学来，偏离笔杆线 8 mm 以上的不学；单摄像头量不出笔尖高度，只能这样学）；字母之间的快速抬笔不加；One Euro 平滑（最小截止 2 Hz，β 0.02/mm） |
| `CameraPen.swift` | AVCapture（优先“桌上视角”设备，取最大分辨率，420f 亮度平面），画面时间 = 到达 − 0.05 s 对上触点；落笔帧学习，悬空帧报告笔尖的触控板坐标（`tipChanged` 通知）；标定存 UserDefaults `cameraPen.calibration` |
| `CameraAlignWindow.swift` | 「显示 → 摄像头对准…」：实时画面、四角拖动、旋转显示、学习进度和“对不准”提示 |
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
swiftc -parse-as-library scripts/test_smoothing.swift $S/{BoardModel,BoardArchive,InkRenderer,StrokeSmoothing}.swift -o /tmp/tsm && /tmp/tsm
swiftc -parse-as-library scripts/test_eraser.swift $S/{BoardModel,BoardArchive,InkRenderer,TrackpadCore,PalmRejection}.swift -o /tmp/te && /tmp/te
swiftc -parse-as-library scripts/test_archive.swift $S/{BoardModel,BoardArchive,InkRenderer}.swift -o /tmp/ta && /tmp/ta /tmp/archive-check.json
swiftc -parse-as-library scripts/test_notes.swift $S/{BoardModel,BoardArchive,InkRenderer,NoteLibrary}.swift -o /tmp/tn && /tmp/tn
swiftc -parse-as-library scripts/test_connector.swift $S/TrackpadCore.swift $S/PalmRejection.swift $S/ConnectorCore.swift -o /tmp/tc && /tmp/tc && /tmp/tc calibration/reference/*.jsonl
swift build --package-path . -c release
```

`test_connector` 不带参数时运行合成用例；带录制文件时，把原始帧回放给连接器，检查按下和抬起是否成对，并统计笔画数和双指手势帧数（手掌、单指、双指录制中的笔画数都应为 0）。

落笔预测回放（用真实书写录制评估 PenAim：先预测再学习，对比“只看手掌”和“加上抬笔点随手移动”两种预测，输出误差毫米数和落在标记圈内的比例；可直接给持续记录的文件夹，.gz 也能读）：

```bash
swiftc -parse-as-library scripts/replay_penaim.swift $S/{TrackpadCore,PalmRejection,PenAim}.swift -o /tmp/aim && /tmp/aim ~/Library/Application\ Support/TrackpadStudio-Handwriting/touchlog/continuous
```

2026-10-10 用 278 次落笔回放：有最近抬笔点时（186 次）中位误差 3.3 mm、90% 在 6.4 mm 内（只看手掌是 4.0 / 8.9 mm）；剩下的多是手整个抬起后重新放下，只能靠手掌位置。

摄像头笔尖跟踪（单元测试 + 用录好的画面回放；画面是逐帧 JPEG，文件名 `名字-序号-uptime.jpg`（uptime 与触点记录同一时钟），四角为 左下 左上 右上 右下 的像素坐标）：

```bash
swiftc -parse-as-library scripts/test_camerapen.swift $S/{PadCalibration,TipTracker}.swift -o /tmp/tcam && /tmp/tcam
swiftc -O -parse-as-library scripts/replay_camerapen.swift $S/{PadCalibration,TipTracker}.swift -o /tmp/camreplay
/tmp/camreplay <画面文件夹> <触点记录.jsonl.gz> "x,y x,y x,y x,y"
```

2026-10-10 用 174 帧桌上视角原始画面（1920×1440）回放：落笔帧在学习之前就找到笔尖，误差中位 1.7 mm、90% 在 2.8 mm 内；悬空帧 31/31 都有可信位置；每帧 1.2 ms。
同日 60 秒、1304 帧（22 帧/秒，44 次落笔）的录制，方块模板 → 沿笔身模板 + 门槛 + 跳错拦截 + HoverCursor：悬空光标“尖刺”（偏离前后两帧连线 > 5 mm）约 11% → 2%；落笔前 0.05 s 光标离落点中位 7.0 → 3.7 mm（90%：15.2 → 8.6 mm）；悬空帧有光标的比例 100% → 79%（看不清时宁可不显示）；每帧 5 ms。剩下的误差主要是落笔前最后几十毫秒笔还在动，以及笔抬得越高视差越大。四角偏 10–15 px 时中位误差仍约 1.7 mm（模板就在标定位置学的，自洽），所以手动拖角只要大致对就行。
同一录制，加上沿笔杆的 reach（学到 7.4 mm）：悬空超过 1 s 再落笔的 6–7 次里，落笔前 0.3 s 光标离落点中位 10.2 → 6.8 mm、0.2 s 12.1 → 8.5 mm、0.1 s 10.9 → 9.7 mm，最后 0.05 s 略差（9.2 → 10.4，笔正沿笔杆往下落）；字母间快速抬笔不变（0.05 s 3.7 mm）。逐帧看：长时间悬空瞄准时落点在笔尖前方 5–24 mm、几乎正好在笔杆延长线上（横向只差 1–4 mm），所以方向用固定的手的方向就够（画面里量的笔杆角度中位 145°，固定方向 149°）。样本少，参数也是在这段录制上挑的，需要更多录制确认。

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
