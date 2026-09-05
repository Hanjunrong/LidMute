# Chrome 非 UI 简化与消融记录

日期：2026-09-05。范围：Chrome 扩展、Native Messaging、心跳与 acceptance 标记、观察存储与 inbox consumer。未改 UI。

## 落地简化

- 删除 `service-worker.mjs` 中无调用者的顶层 `acknowledge(message)`；端口监听器已经直接调用 controller 的同名方法。
- `getAlarm` 和 `clearAlarm` 两套完全相同的回调 / Promise 适配器合并为 `alarmResult(alarms, method, name)`。保留 `chrome.runtime.lastError`、同步异常、Promise rejection 与重复完成防护，且通过 `alarms[method](...)` 保留 receiver。
- 未提高 manifest 的最低 Chrome 105 要求，也未借重构删除兼容逻辑。新增 callback-only alarms 测试，验证恢复 / 清理路径及 receiver；现有 Promise-only tests 继续覆盖另一种路径。

## 对照与消融

| 实验 | 结果 | 决策 |
| --- | --- | --- |
| 原始扩展 `node --test ChromeExtension/service-worker.test.mjs` | 17 / 17 通过 | 基线 |
| 删除上述重复实现和死包装 | 17 / 17 通过 | 保留简化 |
| 增加 callback-only 边界测试后的最终版本 | 18 / 18 通过 | 两种异步接口行为均有覆盖 |
| 临时副本仅取消 outbox 操作之间的 Promise 串行依赖 | 14 / 17 通过，3 项失败 | 保留 outbox 串行队列 |

消融失败项目：交叉 ACK 导致旧事件复活、enqueue 与 ACK 并发丢失新事件、重复乱序 ACK 无法收敛。消融只把 outbox 的 `tail.then(operation, operation)` 改为 `Promise.resolve().then(operation)`，保留 retry scheduler 队列及其余实现。实验位于 `/tmp/lidmute-chrome-serial-ablation`，没有将失败版本写回仓库。命令：

```sh
node --test /tmp/lidmute-chrome-serial-ablation/service-worker.test.mjs
```

## Swift 通路验证

```sh
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache \
SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache \
swift test --disable-sandbox --scratch-path /tmp/lidmute-chrome-ablation \
  --filter 'Chrome|ObservationStoreAcceptance|ObservationClear'
```

结果：44 个 XCTest 与 50 个 Swift Testing 测试全部通过。首次默认缓存运行因沙箱不允许写入用户 clang cache 失败；改用 `/tmp` 缓存后正常编译运行。未使用 `swift build`。该筛选也包括名称含 Chrome / ObservationClear 的跨模块行为测试。

## 复杂性保留理由

以下是代码与定向测试支撑的取舍，不是对所有候选设计的绝对最优证明：

- framing 上限与 schema 校验：碎片 / 粘包、超大消息、无安全 eventId、字节级字符串限制测试覆盖真实协议边界。
- durable inbox + dedup：并非重复记录的无用双写。dedup 写入失败时从 inbox 尾部重建，避免重试再次追加；目录同步失败后的 duplicate 路径需要重新确认耐久性。4096 ID 窗口限制元数据与恢复读取规模。
- generation：清空观察资料后禁止旧 generation 的 acceptance / pending 数据回流；有清空与新写入交错测试。
- heartbeat 与 acceptance 分离：前者说明 host 活着，后者说明当前 session / generation 近期实际接收了事件，不能互相替代。session token 的条件删除和跨进程 flock 防止旧 host 删除新 host 心跳。
- consumer pending delivery / cursor：保护 event store 落盘与应用内投递之间的失败恢复边界；目前不因结构复杂而移除。
- 扩展持久化 retry deadline 与 alarm：service worker 可暂停，单靠内存 timer 不具等价生命周期；已有重启恢复、退避上限及清理失败测试。

限制：Node harness 不等于真实 Chrome 105 与当前 Chrome 的端到端验证；Swift 故障注入不等于真实断电或磁盘故障；本次未进行 inbox 长期增长与 fsync 成本基准，也未改通信协议或持久化格式。因此结论是删除已证实的重复实现并保留有故障语义的复杂性，而不是宣称当前全部设计已达到全局最优。
