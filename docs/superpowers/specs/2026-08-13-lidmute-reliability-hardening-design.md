# LidMute 可靠性、安全与发布加固设计

## 背景与目标

LidMute 当前能够构建并通过核心行为测试，但真实设备保护、应用生命周期、Chrome Native Messaging、本地数据保留和发布身份之间仍存在会导致漏保、误操作、数据丢失或隐私误解的风险。

本次加固的目标是在保留现有 SwiftUI 界面、菜单栏交互和 `ProtectionCoordinator` 核心状态机资产的前提下，使 LidMute 满足以下不变量：

1. 真实合盖保护不能被模拟操作解除。
2. 外接音频设备永远不被 LidMute 写入；保护中的内建扬声器路由变化能够重新进入保护。
3. 对扬声器的首次修改之前必须已有可恢复的持久化快照。
4. 正常退出立即恢复；异常退出后的下一次启动只对 UID 匹配且仍能确认是内建扬声器的设备自动恢复。恢复失败时执行故障安全的重新静音与读取验证：验证成功才允许声称“仍静音”，验证失败则把设备状态标记为未知、保留快照、阻止普通退出并明确告警。
5. Chrome ACK 表示完整消息已经校验并耐久接受，不再表示“未经校验地写入了文件”。
6. 无痕标签页的标题、URL 和其他标签级证据不会进入持久化文件或诊断日志。
7. 普通标签页保留完整 URL，包括查询参数和片段；这一隐私选择必须在界面和文档中明确披露。
8. 磁盘事件记录最多保留最近 5,000 条；清空后旧记录不会在重启时重新出现。
9. 本地验收包和正式分发包具有不同且不可混淆的构建、签名和验证结果。

本设计替代 `2026-07-11-lidmute-protected-media-pause-design.md` 中“保护期间自动发送系统播放/暂停媒体键”的行为。用户主动点击上一首、下一首和播放/暂停按钮仍保留。

## 已确认的产品决定

- 移除 Chrome 或保护状态触发的自动全局 `playPause`。
- 普通 Chrome 标签页持久化完整 URL，包括 query 和 fragment。
- 无痕标签页不落盘；Native Host 返回 `ignored_incognito`，使扩展可以从 outbox 移除该事件。
- 事件日志上限为最近 5,000 条。
- “清空”删除事件、Chrome inbox、去重记录、消费游标以及内存中的当前 Chrome 证据，但保留 Chrome Native Messaging 注册信息和扩展 ID，避免清空日志导致断连。
- 启动发现未完成恢复快照时，仅在可按快照 UID 重新解析且仍能确认是内建扬声器的设备上自动恢复。恢复失败则按故障安全顺序重新静音并读取验证；静音验证成功时保留快照并显示警告，验证失败时将设备安全状态标为未知并显示最高优先级警告。
- 默认打包 Release 二进制。本地验收允许 ad-hoc 签名；正式发布使用 Developer ID、Hardened Runtime 和公证，不允许正式模式失败后静默回退到 ad-hoc。
- 最低支持版本继续为 macOS 15；不增加第三方运行时依赖。

## 方案选择

### 采用：渐进加固并抽取少量深模块

保留现有领域模型、`ProtectionCoordinator` 和 SwiftUI 主界面，仅在当前风险集中的 seam 抽取恢复存储、Chrome 桥接、本地事件存储和健康状态。调用方只接触小接口，文件格式、锁、轮转、恢复事务和错误分类留在模块实现内部。

这样能够复用已有测试，按阶段提交和回滚，同时给未来改用 SQLite 留出存储 seam。

### 未采用：全面 SQLite 与服务化重构

SQLite 能提供事务、查询和并发写入能力，但当前只有单机、小规模时间线和一个 UI 消费者。现在引入 schema migration、数据库 actor 和完整服务层会扩大迁移与验收范围。只有未来出现日志搜索、统计、跨版本迁移或多进程共享查询时再考虑此方案。

### 未采用：在现有文件中做最小补丁

局部条件判断可以快速关闭媒体键或过滤无痕事件，但无法把恢复事务、半帧处理、清理一致性和有界存储集中到一个可测试接口中，会继续造成规则散落和后续 shotgun surgery。

## 架构与模块

### 1. 保护运行时

`ProtectionCoordinator` 继续负责保护状态转换，但输入必须显式区分：

- 真实合盖：`.physicalLid`
- 模拟状态：`.simulation`
- 夜间息屏：`.night`

真实合盖和模拟状态各自维护 observation。模拟状态允许 `closed`、`opened` 和 `reset`；`reset` 表示移除模拟来源，而不是伪造一次物理开盖。最终保护条件为三个来源的 OR。

保护运行时接收默认音频路由变化事件。当任一保护来源有效而当前状态为 `.unavailable`，或默认输出重新成为内建扬声器时，必须重新识别设备并尝试保护。外接蓝牙、USB、显示器和 HDMI 输出不允许进入捕获、静音或恢复调用。

音频设备引用以 UID 作为持久身份。每次写入或恢复前都从系统设备列表按 UID 重新解析 `AudioObjectID`，再次验证 transport 和 data source 确为内建扬声器，不得跨路由变化长期使用旧 ID。

所有保护结束路径使用同一设备资格规则：正常开盖/夜间结束、正常退出和启动恢复都只按快照 UID 查找仍存在且可确认的内建扬声器。该设备可以不是当前默认输出，因此内建 A 切到外接 B 后仍可安全恢复 A，但绝不写 B；A 不存在、UID 改变或无法确认其内建属性时保留快照并进入等待/告警状态，不得把 A 的状态恢复到另一个内建设备 C。

### 2. 扬声器恢复事务

新增持久化恢复快照模块。快照至少包含：

- schema 版本；
- 事务 UUID；
- 内建设备 UID 与可读名称；
- 原始 mute、volume 和 `usedVolumeFallback`；
- 捕获时间；
- 保护来源和应用版本。

保护开始的顺序固定为：

1. 确认目标是当前内建扬声器；
2. 捕获原始状态；
3. 将恢复快照原子写入 `Application Support/LidMute`，并设置目录 `0700`、文件 `0600`；
4. 快照写入成功后才静音或把音量降至 0；
5. 恢复成功后才删除快照。

恢复 adapter 必须采用故障安全写入顺序：

- 设备有可写 mute 属性时，先写入并读取确认 `mute=true`，再恢复原 volume；原状态为 unmuted 时，只有此前步骤成功后才把 unmute 作为最后一次写入并读取确认，任何前置失败都不允许 unmute。
- 设备只能使用 volume fallback 时，恢复原 volume 是唯一可能使设备出声的最终写入；写入失败后立即尝试写回并读取确认 `volume=0`。
- 任一 restore 步骤失败后都执行重新静音和读取验证。验证为 mute 或 volume 0 时结果为 `failedButVerifiedSilent`；静音写入或读取也失败时结果为 `failedSafetyUnknown`，日志和 UI 不得声称设备仍静音。

恢复快照包含事务阶段 `protected` 或 `finalizingRestore`。恢复最终可听状态前先原子写入 `finalizingRestore`。若进程在最后一步与删除快照之间崩溃，下次启动先读取当前设备状态：与目标原状态完全相同则只清除快照；仍是已知安全的中间静音状态则继续恢复；既不等于目标也不等于安全中间状态时不得覆盖可能由用户后来调整的值，进入安全状态未知告警。

正常退出通过幂等 `shutdownAndRestore()` 停止 monitor/timer、恢复扬声器并清除成功完成的快照。macOS 终止流程由 `applicationShouldTerminate` 返回 `.terminateLater`，在最多 5 秒的单调时钟期限内完成 shutdown 后调用 `reply(toApplicationShouldTerminate:)`：恢复成功或 `failedButVerifiedSilent` 时允许退出；`failedSafetyUnknown` 或超时则取消普通退出、显示最高优先级警告，用户仍可通过系统强制退出。重复退出请求复用同一个 shutdown task，不重复恢复。

启动恢复按下列规则执行：

- 没有快照：正常启动。
- 快照损坏或 schema 不支持：不提高音量，显示恢复数据损坏警告。
- 不能按快照 UID 找到仍可确认的内建扬声器：不写任何设备，保留快照并提示等待匹配设备。
- 找到 UID 匹配且仍可确认的内建设备：尝试幂等恢复；成功后删除快照。
- 恢复失败但已读取验证静音：保留快照并显示高优先级警告。
- 恢复失败且无法验证静音：保留快照、把设备状态标为未知并显示最高优先级警告。

不得在恢复成功后仍保留快照，否则下次启动可能覆盖用户后来调整的音量。

启动使用单一生命周期 gate：`recovering -> ready | recoveryBlocked`。App 可以展示只读的恢复进度界面，但在进入 `ready` 前不得启动保护事务、合盖/息屏处理、Chrome 消费或覆盖恢复快照。`recoveryBlocked` 下只启动用于寻找匹配 UID 的音频设备监听；保护开关保持禁用。匹配设备出现并恢复成功后才进入 `ready` 并启动其余 monitor。损坏或不支持的快照保持 blocked 并提供明确的人工诊断信息。

### 3. Chrome 桥接

Native Host 负责 Chrome length-prefixed 消息的完整帧读取、schema 校验、隐私策略和耐久接收，App 不再通过每 0.7 秒读取整个 append-only inbox 来完成协议校验。

协议常量使用 UTF-8 字节数计算：frame 最大 262,144 bytes；`eventId` 和 `extensionSessionId` 必须是 RFC 4122 UUID 且各不超过 64 bytes；title 最大 4,096 bytes；URL 最大 16,384 bytes；status、mute reason 各最大 64 bytes；extension ID 最大 128 bytes。有效 `tab_audio_started` 帧必须满足：

- `v == 1`、`type == tab_audio_started`、`audible == true`；
- `eventId` 和 `extensionSessionId` 是合法 UUID；
- title、URL 和其他字符串字段满足上述长度上限；
- frame 不超过 256 KiB；
- 必需字段类型正确。

无痕帧通过 schema 校验后不写入标题、URL、inbox、事件或诊断日志，返回终态 ACK disposition `ignored_incognito`。普通帧只有在完整记录校验并耐久写入后才返回 `accepted`。ACK disposition 分为：

- `accepted`：首次事件已耐久接受，扩展移除 outbox 项；
- `duplicate`：事件此前已耐久接受，扩展移除 outbox 项，不重复入库；
- `ignored_incognito`：无痕事件按策略忽略，扩展移除 outbox 项；
- `rejected_permanent`：schema、版本、类型、字段或大小永久不合法，扩展移除 outbox 项，并只记录 event ID 和非敏感 reason；
- `retryable_failure`：锁、磁盘、权限或其他暂时持久化失败，扩展保留 outbox 项并退避重试。

无法解析出受长度约束 event ID 的畸形帧返回无 event ID 的 protocol error 后断开连接，不得返回 `accepted`。扩展生成的合法 outbox 项始终具有 UUID event ID。

Native Host 将一条规范化记录连同换行作为一次协调后的追加写入，并使用跨进程锁防止多个 Chrome profile 的 Host 实例交错写入。耐久提交点定义为：在锁内完成整条 record write，并对已存在文件执行 `fsync`；首次创建或原子替换文件时还必须同步其父目录；全部成功后释放锁并返回 `accepted`。提交点之前崩溃不得 ACK，提交点之后重放允许返回 `duplicate`，但不得出现 ACK 后记录丢失。

App 只提交以换行结束的完整记录；读取到半行时保留 remainder，不能提前推进 committed offset。发生截断、轮转或 inode 替换时重置游标并通过去重避免重复事件。去重元数据与事件消费采用可恢复的提交顺序，并以 Chrome `eventId` 作为持久化事件幂等键，确保 crash 只会导致重放，不会导致已 ACK 事件永久丢失或时间线重复。

去重按接受顺序保留最近 4,096 个 ID，不再对随机 UUID 排序后取字典序后缀。重复事件返回幂等 ACK，但不重复写入事件时间线。

扩展端的 outbox 更新必须串行化，多个 ACK、重复 ACK、乱序 ACK 和断线重连不能通过 read-modify-write 竞态复活或丢失其他事件。

### 4. 有界本地存储

事件存储接口隐藏 JSONL 实现，并提供：追加事件、读取最近事件、清空 observation 数据和报告存储健康状态。实现满足：

- 磁盘只保留最近 5,000 条有效事件；
- 超出上限时原子重写或轮转，保留最新记录；
- UI 使用增量 append 或有界 recent 查询，不在每个事件回调中重新读取全部历史；
- 文件目录权限为 `0700`，事件、inbox、去重、恢复快照、origin、PID/heartbeat 文件权限为 `0600`；
- 文件损坏、磁盘满和权限错误不可静默跳过，必须进入健康状态。

普通标签页事件保留用户确认的完整 URL，包括查询参数和片段。界面与 README 必须说明完整 URL 可能包含搜索词、标识符或令牌，数据只保存在本机，用户可随时清空。无痕标签级证据不得进入任何持久化结构。

“清空”作为一个 observation-scope 操作，按同一个协调入口完成。Host accept、App consume 和 clear 共用桥接锁与单调 generation：clear 取得排他锁后暂停 accept/consume，递增并同步 generation，清理磁盘与内存状态后才释放锁。clear 开始前已经 ACK 但尚未进入时间线的旧 generation 事件一并删除；clear 释放锁后才到达的新 generation 事件正常保留。因此 clear 返回后，旧观察数据不会从 remainder、重放或内存缓存中复活。

清理范围包括：

- 删除或截断 `events.jsonl`；
- 删除或截断 Chrome inbox；
- 删除 Chrome 去重 ID 和消费游标/remainder；
- 清除 UI 中的 events、当前 Chrome evidence 和连接的“最近收到事件”状态；
- 保留 Native Messaging manifest、extension origin/ID 和可执行路径注册。

若任一清理步骤失败，UI 显示部分失败以及未清理的类别，不得显示无条件成功。

### 5. 健康状态与生命周期

新增可观察的健康状态，至少区分：

- CoreAudio 正常但没有活动输出；
- CoreAudio 查询失败；
- 合盖 monitor 正常、不可用或读取失败；
- Chrome 未注册、等待连接、已连接、最近接受事件或桥接降级；
- 本地存储正常、部分损坏、权限失败或容量失败；
- 扬声器恢复正常、等待匹配设备、恢复失败但已读取验证静音，或恢复失败且安全状态未知。最后一种必须使用最高优先级警告并阻止普通退出。

诊断使用 `Logger`，不记录无痕标题、URL 或原始帧。用户可见文案要区分“没有数据”和“系统能力不可用”。

Chrome 连接状态不再仅凭残留 PID 判断。Native Host 每 2 秒原子更新包含随机会话 token、PID 和 `ProcessInfo.systemUptime` 的 heartbeat，并在正常退出时清理；App 仅在 heartbeat uptime 不大于当前 uptime 且相差不超过 6 秒时视为已连接。负差值、系统重启、文件损坏或超过 TTL 均视为 stale。旧 manifest 指向移动前路径时，界面提示一键修复，修复仍使用已登记的合法扩展 ID。

### 6. App 层职责

`AppViewModel` 保留 SwiftUI 所需的 published presentation state，但不再实现文件尾读、恢复快照事务、日志裁剪或 Chrome schema 校验。系统 adapter 通过初始化注入，使 CoreAudio 错误、路由变化、文件错误和恢复失败能够测试。

本次只拆出与可靠性加固直接相关的模块，不重做 Control Center Glass 界面，也不进行无关的视图文件拆分。

## 媒体控制语义

自动媒体控制从保护流程中完全移除：

- 合盖、模拟合盖、夜间保护和 Chrome audible 事件都不会发送 `.playPause`；
- `ProtectionCoordinator` 不产生自动 pause request，也不记录“已请求系统暂停”；
- Chrome 证据只用于显示声音来源和加强静音；
- 用户在界面主动点击上一首、下一首或播放/暂停时仍发送对应系统媒体键；
- 文档不再声称 LidMute 会自动暂停网页或播放器。

## 打包、签名与公证

项目仍只能通过 `Scripts/make-app-bundle.sh` 生成最终 App。打包默认使用 `swift build -c release`；`LIDMUTE_SIGNING_MODE` 未设置时确定性采用 `adhoc` 并在输出中显著标记，不允许根据本机证书自动切换模式。产物分为两种显式模式：

### 本地验收模式

- `LIDMUTE_SIGNING_MODE=adhoc`；
- 使用 ad-hoc 身份签名；
- 输出和终端文案明确标记为“本地验收包，不可公开分发”；
- 不包含 `get-task-allow`；
- 仍执行 `codesign --verify --deep --strict` 和 bundle 内容检查。

### 正式分发模式

- `LIDMUTE_SIGNING_MODE=developer-id`；
- 要求 `LIDMUTE_DEVELOPER_IDENTITY` 指定 Developer ID Application identity，`LIDMUTE_NOTARY_PROFILE` 指定已配置的 notarytool keychain profile；固定使用 `Config/LidMuteRelease.entitlements`、Hardened Runtime 和 timestamp；
- 先签 Native Host，再签主程序，最后签 bundle，不依赖 `--deep` 代替正确签名顺序；
- Developer ID 模式每次都使用 `notarytool` 提交、公证成功后 staple，不提供跳过公证的正式分发捷径；
- 验证 `codesign --strict`、`spctl --assess` 和 `stapler validate`；
- identity、公证 profile 或任一步骤缺失/失败时直接失败，不回退 ad-hoc。

打包输出路径在删除或替换前必须 canonicalize，并限制为项目 `dist` 目录的直接子项且 basename 以 `.app` 结尾。必须拒绝根目录、用户 HOME、仓库根目录和其他任意路径。staging 目录使用 `mktemp -d` 创建在同一个 `dist` 文件系统中，成功后用 rename 替换目标；替换前后只删除已经 canonicalize 且仍位于该 staging/backup 范围内的明确路径。

版本号从单一受控文件 `Config/Version.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion` 写入最终 Info.plist，不再把 `0.1.0` 和 build `1` 分散硬编码。

## 测试设计

现有行为可执行 target 迁移为标准 SwiftPM `.testTarget`，使 `swift test` 成为单元与集成测试入口。保留项目打包 smoke check，并增加以下覆盖。

### 保护状态

- 物理 open/closed/unknown 与 simulation reset/open/closed 的组合和乱序序列；
- 物理 closed 后 simulation open/reset 仍保持保护；
- simulation closed 后物理 open 是否继续保护由 simulation 状态决定；
- 重复输入不重复 mute/restore；
- 守卫关闭时输入不留下 active source。

### 音频路由和恢复

- 内建 A -> 外接 B -> 内建 A；
- 保护开始时默认输出为外接设备，之后切回内建；
- 相同 UID 对应新的 AudioObjectID；
- 不同 UID、设备消失以及 capture/enforce/restore 分别失败；
- mute property 和 volume fallback 两条路径；
- 内建 A 切到外接 B 后结束保护或正常退出时，只按 UID 恢复 A且不写 B；
- 正常退出的 `.terminateLater`、成功回复、5 秒超时、重复退出与安全状态未知时取消退出；
- 快照原子写、损坏、旧 schema、UID 匹配/不匹配、恢复成功/失败与幂等启动恢复；
- restore 的 mute、volume、final unmute、读取验证和重新静音各步骤分别注入失败；
- 任一失败场景均不写外接设备，且不得猜测性提高音量或在安全状态未知时声称仍静音。

### Chrome 协议和隐私

- 合法帧、非法 JSON、缺字段、错误 version/type、`audible=false`、空/超长 ID、超长 frame；
- length prefix 与 payload 分片、两个粘连 frame、完整帧后跟半帧、UTF-8 多字节边界；
- 只有完整、合法并跨过 fsync 提交点的帧返回 accepted；提交前/后 crash 分别验证无 ACK 丢失和幂等重放；
- `rejected_permanent` 会移除毒消息，`retryable_failure` 保留并退避，其他三种终态 disposition 均移除对应 outbox 项；
- 持久化失败不会删除扩展 outbox；
- 重复事件返回 `duplicate` 且不重复入库；
- 无痕帧返回 `ignored_incognito`，并对所有持久文件进行零落盘断言；
- 多 ACK、重复 ACK、乱序 ACK 和断线重连不会丢失或复活 outbox 项。

### 本地存储

- 0、1、4,999、5,000、5,001 和 10,000 条边界；
- 重启后仍只保留最新 5,000 条；
- 损坏记录、并发追加、截断和轮转；
- clear 与 Host append/App consume 并发时以 generation barrier 线性化；清空后磁盘、内存、游标和去重状态一致，重启不复现旧数据；
- 清空 observation 数据不会删除 Chrome 注册信息。

### 发布

- Debug 编译用于开发检查，打包产物必须来自 Release；
- signing mode 未设置时确定性生成带醒目标记的 ad-hoc 本地验收包；ad-hoc 模式验证资源、架构、Info.plist、无调试 entitlement 和严格签名；
- Developer ID 模式缺少 identity、notary profile 或 release entitlements 时确定性失败且不回退；
- 有凭据环境验证 Hardened Runtime、嵌套签名、timestamp、公证和 Gatekeeper；
- App 移动到 `/Applications` 后检测并修复 Chrome manifest 路径。

真机最终验收仍需要人工完成：物理合盖/睡眠、真实音频路由热切换，以及正式签名包在干净 macOS 上的 Gatekeeper 首次安装。

## 实施与提交顺序

1. 迁移标准测试入口，并移除自动媒体键保护语义。
2. 分离真实/模拟保护来源，实现路由变化后的安全重试。
3. 实现恢复快照、正常退出恢复和启动自愈。
4. 加固 Native Host 帧验证、ACK、半帧和并发写。
5. 修复扩展 outbox ACK 竞态并落实无痕零落盘。
6. 实现 5,000 条有界存储、增量读取和 observation-scope 清空。
7. 增加健康状态、结构化诊断和 Chrome heartbeat/路径修复。
8. 完成 Release、签名、公证与安全输出路径分轨。
9. 执行全量自动验证、独立代码审查和人工验收清单整理。

每一步遵循 red-green-refactor，并形成可单独审查的提交。实现与审查由不同上下文完成。

## 非目标

- 不注入网页脚本，不控制 DOM 中的媒体元素。
- 不自动暂停、恢复或终止 Chrome 及其他播放器。
- 不把普通标签页 URL 截断为 origin，也不删除 query 或 fragment。
- 不持久化任何无痕标签页证据。
- 不引入 SQLite 或第三方数据库依赖。
- 不重做现有视觉系统、窗口布局或应用图标。
- 不在没有 Developer ID 和公证凭据的环境中假装生成正式分发包。
- 不承诺仅靠自动化替代真实 MacBook 合盖、路由切换和 Gatekeeper 人工验收。
