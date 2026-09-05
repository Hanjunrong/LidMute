# LidMute 非 UI 消融与设计审查

日期：2026-09-05。分支：`codex/non-ui-ablation`，起点为干净的 `master`。目标是删除有证据的冗余，并用反例区分必要防护。没有修改 SwiftUI 界面、视觉配置或交互布局。

## 结论

存在局部过度设计，已经精简；也发现实际功能缺陷，不能认定原实现全部是最佳设计。本轮结论限于已审查路径、指定故障模型和测试集，不构成全局最优证明。

| 实现 | 处理 | 依据 |
| --- | --- | --- |
| ProtectionCoordinator 注入但不读取 processEvidence | 删除属性、参数和多余协议约束，迁移仓库调用点 | 音频快照已通过 receiveAudioSnapshot 输入；核心与 App 测试 |
| 恢复失败后的第二套静音与回读代码 | 复用 silenceAndVerify | 故障注入测试覆盖 mute/volume fallback 和回读失败 |
| Data 读取原样 rethrow | 删除包装 | 错误传播不变 |
| Chrome 两套相同 alarm 回调/Promise 桥接 | 合并 helper | Promise 与 callback-only 测试，保持 receiver 和 Chrome 105 要求 |
| 未调用的顶层 acknowledge 包装 | 删除 | 端口直接调用 controller |
| 音频探针 active 状态 | 删除，保留 NSLock | 状态完全位于串行锁内，无法观察到 active 分支 |
| 4096 样本 scratch、声道平均、首 buffer 限制 | 改为遍历所有 buffer 求独立样本峰值 | 纠正反相抵消、右声道遗漏与截断；新增四项回归 |
| shutdown 第二次 stopAll | 删除 | lifecycleCoordinator.stop 同步停止所有监控 |
| 音频轮询停止边界 | 修正取消后的发布与清理 | 旧查询不能发布结果或清除新查询的任务引用；无需新增代际状态 |

删除公开 initializer 参数是源码 API 变更。仓库内调用点已迁移，未知外部使用者需要同步删除该参数。音频峰值与轮询变更属于功能修复，其余为行为保持精简。没有进行 CPU/能耗基准，不声称性能提升幅度。

## 消融对照

破坏性修改在临时副本执行，不保留到最终源码。

| 临时移除或恢复的机制 | 观察到的失败 | 决定 |
| --- | --- | --- |
| 删除 finalizingRestore 对歧义音量状态的防护 | 2 个断言失败：错误恢复并写入 | 保留防护 |
| 允许新快照覆盖另一待恢复事务 | 应抛错测试失败 | 保留事务身份保护 |
| 删除 Chrome outbox 串行队列 | 3 项并发测试失败：事件复活、丢事件、ACK 不收敛 | 保留串行化 |
| 恢复旧峰值计算语义 | 4 项峰值回归测试失败 | 保留新的逐样本峰值实现 |

已有恢复日志、UID 匹配、回读验证、清空 generation、heartbeat/session、持久化重试和生命周期重入控制分别承担不同职责。不能因为抽象或状态较多就一并删除；本轮只对表中的机制做了实际消融，其余保留判断来自静态审查及已有测试。

## 验证

基线：129 个 XCTest（1 个 opt-in 真机测试跳过，0 失败），96 个 Swift Testing；Chrome 17/17。

最终验证已经完成，结果由 `/tmp/lidmute-ablation-final.log`、`/tmp/lidmute-ablation-node-final.log`、`/tmp/lidmute-ablation-package.log`、各专项报告和独立复核记录共同支持：

- 默认并行的全量尝试未完成：测试线程池被带有 NSCondition/semaphore 同步等待的既有用例占满而挂起，原始日志保留在 `/tmp/lidmute-ablation-parallel-hang.log`，堆栈采样在 `/tmp/lidmute-hung-test.sample.txt`；这次尝试不计为通过。
- 显式 `swift test --disable-sandbox --no-parallel`：133 个 XCTest，1 个 opt-in `LiveAudioProbeTests` 跳过，0 失败；Swift Testing 105 个测试全部通过。最终日志分别记录 `Executed 133 tests, with 1 test skipped and 0 failures` 和 `Test run with 105 tests ... passed`。
- `node --test ChromeExtension/service-worker.test.mjs`：最终 18/18 通过。该结果与 callback-only 边界测试记录在 [Chrome 报告](non-ui-chrome-ablation.md) 中；Node harness 仍不等同于真实 Chrome 端到端验证。
- Release ad-hoc 打包成功：视觉原则源码检查通过，构建完成；`LidMuteNativeHost`、主程序和 bundle 的代码签名均报告 `valid on disk` 并满足 Designated Requirement。产物为 `dist/LidMute.app`。完整输出见 `/tmp/lidmute-ablation-package.log`。
- 路由门控已修复并通过 8 项门控测试：ready 模式保留默认输出 ID 去重；恢复模式将 device-list 变化合并进待处理批次，即使默认输出 ID 不变或暂不可用也不会丢失恢复信号；重复事件仍合并，停止时清理待处理状态。
- 打包陈旧检查已按 target 目录集合收窄；`zsh Scripts/test-release-packaging.sh` 约 77 秒全部通过，覆盖 App-only 增量更新成功、Core 对 App/NativeHost 的陈旧拒绝和 NativeHost-only 陈旧拒绝。该结果为测试级别证据，不等同于 Developer ID、公证或 Gatekeeper 验证。
- 音频轮询停止边界的两个新增回归在旧实现上共报告 3 个 issues：旧 `audioPollCancelledBeforeItsTaskStartsDoesNotStartIO` 仍启动额外 I/O，旧 `cancelledAudioPollCannotPublishOrClearItsReplacement` 发布旧结果并清掉替代任务；修复后的运行两项均通过。独立复核再次运行两项也均通过，记录在 `/tmp/lidmute-poll-review.log`。

可复用命令：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache \
SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache \
swift test --disable-sandbox --no-parallel
node --test ChromeExtension/service-worker.test.mjs
LIDMUTE_SIGNING_MODE=adhoc \
LIDMUTE_SCRATCH_PATH=/tmp/lidmute-ablation-package \
zsh Scripts/make-app-bundle.sh
```

作者与复核分开：核心/峰值/退出精简由 Chrome 审查代理独立复核；Chrome 修改由核心审查代理独立复核。两条复核均无阻断项，分别重新执行针对性测试；Chrome 串行化消融也由复核者重跑确认。音频轮询修复另有独立复核，`/tmp/lidmute-poll-review.log` 记录两项回归均通过。主线程最终审查通过路由 mode/source 与 target 级打包检查收窄。上述证据限于列出的改动和故障模型，不扩展为全局最优结论。

## 尚未证明的边界

- 显示监控启动时没有息屏状态快照，已息屏时启动的行为需要真机与事件注入验证。
- 真机音频路由热插拔（蓝牙/USB/显示器切换）仍未验证；上述 8 项路由门控测试只覆盖逻辑合并与去重。
- 本次验证为 Release ad-hoc；Developer ID、公证、Gatekeeper 和干净 macOS 首次安装仍未验证。
- 盖子/音频/夜间轮询频率，尚无功耗与反应延迟对照；不能据此认定通知或常驻 tap 更优。
- 真机合盖、睡眠唤醒、蓝牙/USB/显示器音频切换、Chrome 105/当前 Chrome 端到端、强杀与断电恢复，未由此次单元测试替代。

详细命令、失败断言和保留理由见 [核心报告](non-ui-core-ablation.md)、[Chrome 报告](non-ui-chrome-ablation.md) 和 [App 报告](non-ui-app-audit.md)。
