# 非 UI App 层消融审查

审查日期：2026-09-05。报告始于独立静态审查，随后执行下列修复和回归；行号指本次修改前版本。范围为 AppViewModel、系统监视器、音频探针、生命周期和打包入口。未修改 UI，未宣称真机功能全部验证或全局最优。

## 本轮执行结果

- 已删除探针冗余 active、scratch/混音/首 buffer 截断，以及退出流程重复 stopAll。主线程完成改动；独立 reviewer 已检查核心、峰值和退出改动。
- 峰值消融实验：主线程在临时副本恢复旧声道平均、首 buffer break、4096 截断语义，`ProcessAudioPeakTests` 的反相、第二 buffer、4096 之后峰值、非有限值 4 项全部失败；当前实现 4 项全部通过。旧语义实验日志为 `/tmp/lidmute-peak-mutation.log`，副本位置见 `/tmp/lidmute-peak-ablation-path`。
- 已修复旧音频轮询越过停止边界：在外层 Task 开始和结果发布前检查取消；仅未取消的 Task 清理任务槽。取消清理由 stopAll 负责，因此无需新增代际字段。代码依赖既有事实：该私有 task 的取消路径仅在 stopAll，并且 stopAll 同步清空两槽。
- 两个新增阻塞轮询测试先对旧实现运行：全部失败，分别证明额外启动 I/O、发布旧结果以及旧 defer 清新任务。修复后新增 2 项和原有音频查询失败/保留最后快照 2 项共 4 项全部通过。日志为 `/tmp/lidmute-poll-before.log` 与 `/tmp/lidmute-poll-after.log`；测试位于 `Tests/LidMuteAppTests/AppViewModelAudioPollingTests.swift`。
- 路由门控已修复：ready 模式保留默认输出 ID 去重；恢复模式将 device-list 变化合并进待处理批次，即使默认输出 ID 不变或暂不可用也不会丢失恢复信号。8 项门控测试覆盖稳定默认输出、默认输出不可用、待处理批次合并、模式切换、停止清理和基线更新；真机热插拔仍未验证。
- 打包陈旧检查已按 target 目录集合收窄；`Scripts/test-release-packaging.sh` 约 77 秒全部通过，覆盖 App-only 增量更新成功、Core 对 App/NativeHost 的陈旧拒绝和 NativeHost-only 陈旧拒绝。当前 Release ad-hoc 包也已成功并通过签名验证。

## 最终验证

- 显式 `swift test --disable-sandbox --no-parallel` 通过：133 个 XCTest，1 个 opt-in `LiveAudioProbeTests` 跳过，0 失败；Swift Testing 105 个测试全部通过。日志为 `/tmp/lidmute-ablation-final.log`。
- 默认并行的全量尝试未完成：带有 NSCondition/semaphore 同步等待的既有故障注入用例占满 cooperative executor 线程池而挂起，未计为通过。原始日志为 `/tmp/lidmute-ablation-parallel-hang.log`，堆栈采样为 `/tmp/lidmute-hung-test.sample.txt`。
- `node --test ChromeExtension/service-worker.test.mjs` 最终 18/18 通过，日志为 `/tmp/lidmute-ablation-node-final.log`。
- Release ad-hoc 打包和签名验证通过，产物为 `dist/LidMute.app`，输出为 `/tmp/lidmute-ablation-package.log`。主线程最终审查通过路由 mode/source 与 target 级打包检查收窄；这些是代码和测试级别证据，不扩展为全局最优结论。

## 首选消融

1. `Sources/LidMuteApp/ProcessAudioLevelProbe.swift:15-22`：`active` 位于覆盖整个函数的 `NSLock` 临界区内。第二个调用取得锁之前，第一个调用已通过 defer 清除 active；无法通过该标志检测并发。删除字段、guard、赋值及清理，保留锁。递归调用也会先阻塞在非递归锁上，该标志同样无效。
2. 同文件 `115-139`：4096 元素 scratch、手工声道平均及只处理首个 buffer 的 break 不服务于“是否存在非静音样本”的目标。反相立体声 `[0.1, -0.1]` 经平均后为零，会误判静音；非交错右声道独有信号也可能被首 buffer 限制漏掉。直接遍历各 buffer 的浮点样本求绝对峰值，可同时删除分配、拷贝、混音和释放代码。测试应覆盖反相、多个 buffer、阈值、空输入与非有限值。仍需真机验证生产 tap 的格式、权限与资源清理。
3. `AppViewModel.swift:479-483`：`lifecycleCoordinator.stop()` 已调用 `monitors.stopAll()`，紧接着再次调用 `stopAll()` 是重复停止。可以消融第二处，但应先确认所有退出路径仍经生命周期停止，并检验停止次数和取消终止后恢复。

## 发现的边界和测试缺口

### 旧音频轮询越过停止边界

`AppViewModel.swift:800-815` 只在取得结果后检查 ready 和 isShuttingDown，没有检查取消或代际。`stopAll():455-458` 取消并置空两层 task，但同步 detached poll 不检查取消。复现顺序：

1. 注入阻塞的 `AudioProcessPolling`，启动第一次 poll A，等它进入同步查询。
2. 调用 stopAll；它取消 A 并清空 task 槽。生产上对应退出尝试开始。
3. 退出取消后恢复 ready，再启动 poll B，并保持 B 阻塞。单元测试可直接使用固定 ready 的 `LifecycleStateProviding`，stopAll 后启动 B，避免启动真实监视器。
4. 释放 A：旧结果仍满足 ready / 非 shuttingDown，回写 currentAudioProcesses；旧 defer 又把 B 的 task 槽清为 nil。
5. 再次调用 poll，可启动 C，破坏“只允许一个查询在途”的保证。

现成注入点：初始化参数 `audioPoller`（277）和 `lifecycle`（269）。新增测试的阻塞 poller 使用 NSCondition 和逐调用编号，断言 A 结果不发布、A 完成后 B 仍占槽、B 结果正常发布，并验证 B 结束后可以发起 C。修复同时保护发布与 defer 清理；只在发布前添加取消检查是不够的。

### 路由去重与恢复信号（已修复，测试级别）

修复前，`SystemAudioRouteMonitor` 同时监听设备列表变化，却仅按默认输出 ID 去重；等待恢复的目标设备重新出现而默认输出不变，或默认输出暂不可用时，设备通知可能被抑制。当前实现保留 ready 模式的默认输出 ID 去重，`start(reportDeviceListChanges: true)` 为恢复模式开启设备列表信号；设备列表回调记录待处理位，待处理的默认输出任务评估时合并该位，再按当前默认输出更新基线并发布恢复信号。重复事件仍合并，停止时清理待处理状态。

`SystemAudioRouteMonitorTests.swift` 的 8 项门控测试覆盖稳定默认输出、默认输出不可用、待处理批次合并、模式切换、停止清理和基线更新。它们证明当前逻辑的测试级别行为；真实 CoreAudio 设备热插拔、蓝牙/USB/显示器切换仍需真机验证。

### 非幂等盖子监视器与显示初始状态

`SystemLidMonitor.swift:21-25` 连续 start 会覆盖 timer 引用，旧 timer 继续运行。当前 AppViewModel 通过 monitor 为 nil 才创建绕开此问题，因此不是已证实的用户路径故障。start 加 guard 或明确定义一次性实例契约可解决。`SystemDisplayMonitor.swift:13-22` 仅订阅后续睡眠/唤醒，没有启动时状态快照；在已经息屏时启用监视器，night protection 会沿用默认 false，直到下一次通知。需要事件注入测试和实际 macOS 状态读取设计，不能仅据单元测试称最优。

### 打包时间戳检查（已修复）

`Scripts/make-app-bundle.sh:83-94` 原先分别要求全部 `Sources` 文件不比两个二进制新。在隔离副本中，首次 release 打包成功；仅在 `Sources/LidMuteApp/AppViewModel.swift` 增加一行无行为注释后，SwiftPM 重链 App 而保留旧 NativeHost，原脚本退出 67 并输出：

`Refusing to package stale binary: /tmp/lidmute-package-repro.Oq4ZbO-scratch/arm64-apple-macosx/release/LidMuteNativeHost is older than /private/tmp/lidmute-package-repro.Oq4ZbO/repo/Sources/LidMuteApp/AppViewModel.swift`

当前检查按 `Package.swift` 的 target 依赖收窄：`LidMuteApp` 检查 `Sources/LidMuteApp` 与 `Sources/LidMuteCore`，`LidMuteNativeHost` 检查 `Sources/LidMuteNativeHost` 与 `Sources/LidMuteCore`。release build、签名和陈旧拒绝仍保留。回归中先 `touch` App 源文件，再删除临时 scratch 中的 `LidMuteApp` 可执行文件，以确保 App 实际重链；NativeHost 未删除，继续使用原二进制验证 App-only 更新边界。

`zsh Scripts/test-release-packaging.sh` 约 77 秒完成，包含临时源码副本上的真实 release build/signing，新增回归覆盖 App-only 更新成功、Core 对 App 和 NativeHost 分别拒绝、NativeHost-only 更新拒绝。各场景日志位于退出即清理的 `/tmp/lidmute-package-policy.XXXXXX` 临时目录；隔离复现日志也已清理。主线程成功打包日志保留在 `/tmp/lidmute-ablation-package.log`。边界是该验证针对当前 macOS 工具链和 mtime 陈旧策略，未执行 Developer ID 公证流程，也未触碰原仓库 `dist`。

## 暂不消融

- 1 秒盖子轮询：目前没有替代信号，删除会丢失合盖检测；要用通知替代必须检验睡眠前时序与外屏合盖。
- 1 秒音频轮询：承担音频快照输入。可实验降低频率或常驻 tap，但当前无 CPU、延迟、短促声音漏检基线，不能声称更优。
- 15 秒夜间计时器：负责跨越时段边界；直接删除会使已息屏设备直到下一外部事件才切换保护。可改为下一边界单次调度，但要覆盖时钟更改、睡眠恢复。
- 生命周期 recoveryGeneration、pending 和 in-progress：针对 await 重入、停止/恢复和退出超时收敛，已有专门测试。不能把多处相似标志直接视作重复。
- AppViewModel 的 typed storage health 与展示消息双轨确有维护成本（252-260、1281-1390），但承载不同错误细节和严重度，且涉及可见展示契约；本轮非 UI 范围不合并。

## 验证结论范围

现有 LiveAudioProbeTests 为 opt-in 且只验证枚举不崩溃和返回对象标记 active；不验证已知音源识别、反相音、权限拒绝、延迟、设备切换或资源泄漏。合理结论只能是“所选消融在指定回归集下成立”，不能是“所有功能实现均为最佳设计”。
