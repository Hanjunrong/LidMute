# 非 UI 核心保护与恢复消融审查

日期：2026-09-05。范围：ProtectionCoordinator、SpeakerRecoveryRuntime、FileSpeakerRecoveryStore 及其调用点；未调整 UI。

## 接受的简化

1. 删除 ProtectionCoordinator 从不读取的 `processEvidence` 存储与构造参数。音频进程证据通过 `receiveAudioSnapshot` 输入，AppViewModel 继续持有实际采样职责；保留 AudioProcessEvidenceProviding 协议。相应删除 convenience initializer 无必要的协议约束，并迁移仓库所有调用点。这是初始化 API 的源码兼容性变化，仓库内全部迁移；未知外部调用方需要删除该参数。
2. 失败后的重新静音直接复用 `silenceAndVerify`，删除第二套 mute/volume fallback 与回读代码。验证失败抛出后仍映射为 failedSafetyUnknown；成功仍为 failedButVerifiedSilent。原有故障注入测试覆盖每次恢复读写失败、再次静音失败及无 mute 能力设备。
3. 删除 FileSpeakerRecoveryStore 读取 Data 时仅原样 rethrow 的 do/catch，保留同样错误传播。

## 拒绝的消融

所有破坏性实验位于 `/tmp/lidmute-core-mutant` 临时源码副本，共享工作树始终保留可靠性机制。

| 移除项 | 实验 | 结果 | 决定 |
| --- | --- | --- | --- |
| finalizingRestore 遇到非原状态且非静音状态时拒绝恢复 | 删除 isVerifiedSilent(current) guard | testFinalizingRecoveryRefusesAmbiguousStateWithoutWriting 失败 2 个断言：错误返回 restored，且发生写入 | 保留，防止崩溃后覆盖用户已改变的音量 |
| 新快照不能覆盖其他待恢复事务 | 将 saveBeforeMutation 已有快照分支改为直接 writeLocked(snapshot) | testSaveRejectsDifferentPendingTransaction 失败：未抛错 | 保留，防止保护前原始状态被新快照覆盖 |

## 验证命令与结果

默认 swift test 因用户缓存目录写权限失败；将缓存及 scratch 放在 /tmp 后成功，无需提权，未使用 swift build。

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/lidmute-core-clang-cache swift test --disable-sandbox --cache-path /tmp/lidmute-core-swift-cache --scratch-path /tmp/lidmute-core-ablation --filter 'SpeakerRecovery|Protection'
```

基线及前两处等价简化后：47 个 XCTest、3 个 Swift Testing 测试通过。删除无用依赖后扩大验证：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/lidmute-core-clang-cache swift test --disable-sandbox --cache-path /tmp/lidmute-core-swift-cache --scratch-path /tmp/lidmute-core-ablation --filter 'SpeakerRecovery|Protection|AppViewModelObservation'
```

最终：47 个 XCTest、34 个 Swift Testing 测试通过。日志：`/tmp/lidmute-core-baseline.log`、`/tmp/lidmute-core-final.log`。

两个消融分别执行以下命令，返回非零且仅预期目标断言失败：

```sh
env CLANG_MODULE_CACHE_PATH=/tmp/lidmute-core-clang-cache swift test --package-path /tmp/lidmute-core-mutant --disable-sandbox --cache-path /tmp/lidmute-core-swift-cache --scratch-path /tmp/lidmute-core-mutant-build --filter SpeakerRecoveryRuntimeTests.testFinalizingRecoveryRefusesAmbiguousStateWithoutWriting
env CLANG_MODULE_CACHE_PATH=/tmp/lidmute-core-clang-cache swift test --package-path /tmp/lidmute-core-mutant --disable-sandbox --cache-path /tmp/lidmute-core-swift-cache --scratch-path /tmp/lidmute-core-mutant-build --filter SpeakerRecoveryStoreTests.testSaveRejectsDifferentPendingTransaction
```

日志：`/tmp/lidmute-core-mutant.log`、`/tmp/lidmute-core-mutant-transaction.log`。

## 设计判断与边界

现有 prepare/apply/complete 分阶段协调、串行转换链、观察日志异步队列、日志清理边界解决不同的一致性问题，不能仅因分层多而删除。快照先落盘、设备 UID 匹配、finalizingRestore 阶段、读回验证、失败再次静音与事务身份检查均有具体安全语义。文件锁、原子 rename、fsync 服务跨进程和崩溃持久性；本次没有断电/进程强杀测试，不能声称已证明所有持久化细节最优。

本次证据支持已接受的行为保持简化，并证明两个防护不可直接移除；不能证明所有实现都是全局最佳设计，也不覆盖真实硬件音频路由、睡眠唤醒和断电行为。仍应由主任务执行整体测试及打包验证，并独立审查最终 diff。
