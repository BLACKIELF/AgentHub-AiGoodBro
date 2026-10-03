#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPORT_DIR="$ROOT_DIR/${BUILD_DIR:-build}/memory-risk"
REPORT_FILE="$REPORT_DIR/report.md"
mkdir -p "$REPORT_DIR"

FAILURES=0
FAILURE_MESSAGES=()

fail() {
  FAILURE_MESSAGES+=("$1")
  FAILURES=$((FAILURES + 1))
}

SWIFT_SOURCES=()
while IFS= read -r -d '' source; do
  if [[ -f "$source" ]]; then
    SWIFT_SOURCES+=("$source")
  fi
done < <(git ls-files -z --cached --others --exclude-standard -- \
  'Sources/CodexUsageWidget/*.swift' 'Sources/CodexUsageWidget/**/*.swift')

if (( ${#SWIFT_SOURCES[@]} == 0 )); then
  printf 'Memory risk gate: no Swift sources found\n' >&2
  exit 2
fi

scan_regex() {
  local pattern="$1"
  local matches
  local status=0
  matches="$(/usr/bin/grep -nH -E -- "$pattern" "${SWIFT_SOURCES[@]}")" || status=$?
  if (( status > 1 )); then
    printf 'Memory risk gate: source scan failed for pattern: %s\n' "$pattern" >&2
    return "$status"
  fi
  printf '%s' "$matches"
}

forbid_regex() {
  local pattern="$1"
  local description="$2"
  local matches
  if ! matches="$(scan_regex "$pattern")"; then
    exit 2
  fi
  if [[ -n "$matches" ]]; then
    fail "$description"
    printf '%s\n' "$matches" >"$REPORT_DIR/forbidden-$FAILURES.txt"
  fi
}

require_literal() {
  local file="$1"
  local literal="$2"
  local description="$3"
  if ! grep -Fq -- "$literal" "$file"; then
    fail "$description"
  fi
}

require_swift_literal() {
  local literal="$1"
  local description="$2"
  if ! /usr/bin/grep -Fq -- "$literal" "${SWIFT_SOURCES[@]}"; then
    fail "$description"
  fi
}

count_regex() {
  local pattern="$1"
  local matches
  if ! matches="$(scan_regex "$pattern")"; then
    return 2
  fi
  if [[ -z "$matches" ]]; then
    printf '0'
  else
    printf '%s\n' "$matches" | wc -l | tr -d ' '
  fi
}

# Async FileHandle callbacks can enqueue without backpressure and repeatedly fire
# at EOF on older Foundation implementations. Production streams must use bounded
# read loops instead.
forbid_regex 'readabilityHandler|availableData' '发现 FileHandle readabilityHandler/availableData；必须改为有背压和 EOF 退出的有界读取循环'
forbid_regex 'readDataToEndOfFile' '发现无界 readDataToEndOfFile；必须改为分块且设总量上限的读取'
forbid_regex 'standardError[[:space:]]*=[[:space:]]*Pipe\(' '发现未证明会被排空的 stderr Pipe；必须消费或重定向到 nullDevice'
forbid_regex 'read\(upToCount: self\.maximumReadChunkBytes\)' '发现 app-server 使用 Foundation 定长 pipe 读取；长连接必须使用能立即返回部分数据的 POSIX read'

if ! repeating_timers="$(scan_regex 'Timer\.scheduledTimer\(.*repeats: true')"; then
  exit 2
fi
if [[ -n "$repeating_timers" ]]; then
  while IFS= read -r timer_line; do
    if [[ "$timer_line" != *'[weak self]'* ]]; then
      fail "重复 Timer 未在创建行使用 [weak self]：$timer_line"
    fi
  done <<<"$repeating_timers"
fi

require_literal Sources/CodexUsageWidget/Services/CodexAppServerTaskClient.swift \
  'private let maximumOutputBufferBytes' 'app-server 流缺少明确的缓冲区上限'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'count <= maximumOutputBytes - receivedBytes' '本地子进程输出缺少累计字节上限'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'POSIX_SPAWN_SETPGROUP' '本地子进程缺少本次启动专用进程组'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'POSIX_SPAWN_CLOEXEC_DEFAULT' '本地子进程缺少默认 close-on-exec 描述符隔离'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'flags | FD_CLOEXEC' '本地子进程 pipe 缺少 close-on-exec 标记'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'processGroupExists(pid: pid)' '本地子进程成功路径缺少进程组退出核验'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'Darwin.kill(-pid, SIGKILL)' '本地子进程组缺少超时强制收尾'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'waitForExit(pid: pid' '本地子进程 terminate/kill 后缺少有界 reap 等待'
require_literal Sources/CodexUsageWidget/Services/BoundedLocalProcess.swift \
  'maximumOutputBytes >= 0' '本地子进程输出上限参数缺少安全校验'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'data = try BoundedLocalProcess.run(' 'SQLite 读取必须在子进程运行时持续排空输出'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'WITH RECURSIVE x(n)' 'SQLite 超时回归覆盖缺失'
require_literal Sources/CodexUsageWidget/Services/FeishuWebhookService.swift \
  'data.count < Self.maximumResponseBytes' '飞书响应必须在读取过程中限制累计字节'
require_literal Sources/CodexUsageWidget/Services/FeishuWebhookService.swift \
  'bytes.task.cancel()' '飞书响应流必须在超限或完成时关闭网络任务'
require_literal Sources/CodexUsageWidget/Services/PublicResetAnnouncements.swift \
  'data.count < 512 * 1024' '公开公告响应缺少读取过程中的总量上限'
require_literal Sources/CodexUsageWidget/Services/AccountAutomationAuditStore.swift \
  'static let maximumArchiveBytes' '自动化审计归档缺少明确的总量上限'
require_literal Sources/CodexUsageWidget/Services/AccountAutomationAuditStore.swift \
  'DispatchParticipationSync.readBoundedRegularFile(' '自动化审计归档读取缺少普通文件与有界读取门禁'
require_literal Sources/CodexUsageWidget/Services/AccountAutomationAuditStore.swift \
  'guard data.count <= Self.maximumArchiveBytes' '自动化审计归档写入缺少编码后总量门禁'
require_literal Sources/CodexUsageWidget/Services/AccountAutomationAuditStore.swift \
  'var events = try readEvents()' '自动化审计 append 不得把读取失败的历史当空记录覆盖'
require_literal Sources/CodexUsageWidget/Services/AFUnixWebSocket.swift \
  'maximumMessageBytes' '共享 daemon WebSocket 缺少明确的消息上限'
require_literal Sources/CodexUsageWidget/Services/AFUnixWebSocket.swift \
  'payloadLength == 127' '共享 daemon WebSocket 缺少 64 位帧长度处理'
require_literal Sources/CodexUsageWidget/Services/AFUnixWebSocket.swift \
  'SecRandomCopyBytes' '共享 daemon WebSocket 客户端帧缺少安全随机掩码'
require_swift_literal 'POSIXPipeReader.readChunk(' '一次性额度读取没有使用可返回部分数据的 POSIX 分块读取'
require_swift_literal 'from: outputDescriptor' '一次性额度读取没有连接到独立的 POSIX pipe descriptor'
require_swift_literal '--self-test-app-server-pipe' '缺少 app-server 部分响应读取自测入口'
require_literal scripts/self-tests.txt \
  '--self-test-app-server-pipe' '统一自测清单没有包含 app-server 部分响应读取回归测试'
require_literal scripts/build-release-artifacts.sh \
  'make test' '发布包装没有复用统一自测入口'
require_literal scripts/build-release-artifacts.sh \
  'BUNDLE_COMPANION=1' '正式 macOS 发布包装没有强制包含 Next companion'
require_literal scripts/build-release-artifacts.sh \
  "'runtime-paths.json', 'runtime-python.txt'" '正式包缺少私有 runtime 绑定文件排除验证'
require_literal Sources/CodexUsageWidget/Services/CodexAppServerTaskClient.swift \
  'pendingThreadListIDs.first' 'thread/list 缺少单一在途请求约束'
require_literal Sources/CodexUsageWidget/Services/CodexAppServerTaskClient.swift \
  'threadListTimeoutSeconds' 'thread/list 缺少超时回收'
require_swift_literal 'private static let memorySessionUsageCacheLimit' 'session 内存缓存缺少独立数量上限'
require_swift_literal 'private static let maximumPersistentCacheBytes' '持久缓存读取缺少字节上限'
require_literal Sources/CodexUsageWidget/Services/CodexUsageReader.swift \
  'maximumBytes: 4 * 1_024 * 1_024' 'Skill 静态统计读取缺少 4 MiB 过程内上限'
require_literal Sources/CodexUsageWidget/Services/CodexUsageReader.swift \
  'maximumBytes: Int(Self.maximumPersistentCacheBytes)' 'session 缓存读取缺少通用有界普通文件读取器'
require_literal Sources/CodexUsageWidget/Services/CodexUsageReader.swift \
  'guard Int64(data.count) <= Self.maximumPersistentCacheBytes else { return }' 'session 缓存写入缺少编码后体积门禁'
require_literal Sources/CodexUsageWidget/Services/ModelInferenceHistoryStore.swift \
  'maximumBytes: Int(maximumArchiveBytes)' '推理历史读取缺少 32 MiB 过程内上限'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'maximumBytes: min(limits.maximumFileBytes, remainingBytes)' 'Grok 会话读取缺少单文件与全扫描字节上限'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'entryCount <= limits.maximumEntries' 'Grok 会话遍历缺少数量上限'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'end - start <= limits.maximumLineBytes' 'Grok 单行解析缺少工作集上限'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'ProcessInfo.processInfo.systemUptime - started < limits.timeout' 'Grok 全时段扫描缺少耗时上限'
require_literal Sources/CodexUsageWidget/Services/CCSwitchUsageReader.swift \
  'guard !pair.overflow, !sum.overflow else { return nil }' 'Grok 聚合缺少溢出退出路径'
require_literal Sources/CodexUsageWidget/Services/UsageStore.swift \
  'quotaResetRefreshAttempts.filter { activeProfileIDs.contains($0.key) }' '额度到期重试记录必须随账号删除而清理'
require_literal Sources/CodexUsageWidget/Services/UsageStore.swift \
  'quotaResetRefreshAttempts.removeAll()' '额度到期重试记录缺少停止时清理'
require_literal Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift \
  'data.count > maximumBytes - chunk.count' '本地 CLI 额度响应缺少读取过程中的累计字节限制'
require_literal Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift \
  'configuration.timeoutIntervalForResource = 15' '本地 CLI 额度响应缺少总时限'
require_literal Sources/CodexUsageWidget/Services/LocalCLIQuotaReader.swift \
  'defer { session.invalidateAndCancel() }' '本地 CLI 额度会话缺少结束后取消与释放'
require_literal Sources/CodexUsageWidget/Services/LocalCLIAccountStore.swift \
  'quotas = quotas.filter { activeIDs.contains($0.key) }' '本地 CLI 账号重新扫描后必须清理失效额度缓存'
require_literal Sources/CodexUsageWidget/Services/LocalCLIAccountStore.swift \
  'requests = requests.filter { activeIDs.contains($0.key) }' '本地 CLI 账号重新扫描后必须清理失效请求标识'
require_literal Sources/CodexUsageWidget/Services/LocalCLIAccountStore.swift \
  'tasks.removeValue(forKey: id)?.cancel()' '本地 CLI 账号移除后必须取消失效刷新任务'
require_literal Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  'static let maximumConfigurationBytes' '调度配置读取缺少明确的字节上限'
require_literal Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  'while result.count <= maximumBytes {' '调度配置读取缺少运行中总量限制'
require_literal Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  'read(upToCount: min(64 * 1_024, remaining))' '调度配置读取缺少有界分块读取'
require_literal Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  'result.count <= maximumBytes,' '调度配置读取缺少读取后的总量门禁'
require_literal Sources/CodexUsageWidget/UI/CodexAccountManagerView.swift \
  'private static let maximumCatalogBytes' '调度编号静态缓存缺少独立的小文件读取上限'
require_literal Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  'static let maximumCatalogEntries' '调度编号缓存缺少条目数量上限'
require_literal Sources/CodexUsageWidget/Services/DispatchParticipationSync.swift \
  'static let maximumCatalogFieldBytes' '调度编号缓存缺少标识字段长度上限'
require_literal Sources/CodexUsageWidget/Services/WorkspaceScreenshotExporter.swift \
  'static let maximumRGBABytes' '长截图渲染缺少明确的 RGBA 工作集上限'
require_swift_literal 'releaseSessionUsageWorkingSet()' '完成聚合后没有释放 session 工作集'
forbid_regex 'let parsedSessions:.*SessionUsageCacheEntry' '发现全量保留 SessionUsageCacheEntry；session 聚合必须依赖有界缓存并逐项处理'
require_swift_literal 'let sourceByThreadId = Dictionary(' '分支去重缺少轻量 source 索引，可能退化为全量保留 session entry'
require_literal Sources/CodexUsageWidget/Services/PerformanceMonitor.swift \
  'summary.samples.removeFirst' '性能操作样本缺少淘汰逻辑'
require_literal Sources/CodexUsageWidget/Services/PerformanceMonitor.swift \
  'self.resources.removeFirst' '性能资源样本缺少淘汰逻辑'
require_swift_literal 'NotificationCenter.default.removeObserver(systemTimeZoneObserver)' 'UsageStore observer 缺少对应清理'
require_swift_literal 'windowObservers.forEach(NotificationCenter.default.removeObserver)' '窗口 observer 集合缺少统一清理'
require_swift_literal 'NSEvent.removeMonitor(monitor)' '全局/局部事件 monitor 缺少对应清理'

if ! git diff --check >/dev/null; then
  fail 'git diff --check 未通过'
fi

process_count="$(count_regex 'Process\(\)')"
pipe_count="$(count_regex 'Pipe\(\)')"
timer_count="$(count_regex 'Timer\(')"
observer_count="$(count_regex 'addObserver\(')"
data_contents_count="$(count_regex 'Data\(contentsOf:')"
static_collection_count="$(count_regex 'static var .*[\[\(].*[\]\)]')"
parent_traversal_count="$(count_regex 'deletingLastPathComponent\(\)')"

{
  printf '# Codex Account Manager Next 全局内存风险门禁\n\n'
  if (( FAILURES == 0 )); then
    printf '结论：**PASS**\n\n'
  else
    printf '结论：**FAIL**（%d 项阻断）\n\n' "$FAILURES"
  fi
  printf '## 自动阻断检查\n\n'
  printf -- '- 异步 FileHandle EOF 与无背压读取：已扫描\n'
  printf -- '- app-server pipe 部分响应与 EOF 读取语义：已扫描\n'
  printf -- '- 无界整文件/整进程输出读取：已扫描\n'
  printf -- '- 未排空 stderr Pipe：已扫描\n'
  printf -- '- 重复 Timer 强引用：已扫描\n'
  printf -- '- app-server 缓冲、请求并发与超时上限：已扫描\n'
  printf -- '- session/性能缓存上限与工作集释放：已扫描\n'
  printf -- '- 调度配置有界分块读取、运行中总量与编号静态缓存上限：已扫描\n'
  printf -- '- session 聚合全量 entry 保留：已扫描\n'
  printf -- '- 文件系统父路径上溯终止与循环去重：已扫描\n'
  printf -- '- Notification/KVO/Event monitor 清理路径：已扫描\n\n'
  printf '## 全局风险面清单\n\n'
  printf '| 风险面 | 数量 | 发布评审要求 |\n'
  printf '| --- | ---: | --- |\n'
  printf '| Process 创建点 | %s | 核对退出、超时、pipe 排空 |\n' "$process_count"
  printf '| Pipe 创建点 | %s | 核对读取上限和关闭路径 |\n' "$pipe_count"
  printf '| Timer 创建点 | %s | 核对 weak capture 与 invalidate |\n' "$timer_count"
  printf '| Notification observer | %s | 核对 removeObserver 生命周期 |\n' "$observer_count"
  printf '| Data(contentsOf:) | %s | 核对输入可信度和文件大小上限 |\n' "$data_contents_count"
  printf '| 静态可变集合候选 | %s | 核对容量上限和淘汰策略 |\n' "$static_collection_count"
  printf '| 父路径上溯点 | %s | 核对根目录终止、循环去重与异常 Foundation 行为 |\n' "$parent_traversal_count"

  if (( FAILURES > 0 )); then
    printf '\n## 阻断项\n\n'
    for message in "${FAILURE_MESSAGES[@]}"; do
      printf -- '- %s\n' "$message"
    done
  fi

  printf '\n报告仅包含代码结构统计，不读取或写入用户 usage、线程正文、路径或账户数据。\n'
} >"$REPORT_FILE"

if (( FAILURES > 0 )); then
  printf 'Memory risk gate: FAIL (%d)\n' "$FAILURES" >&2
  printf 'Report: %s\n' "$REPORT_FILE" >&2
  exit 1
fi

printf 'Memory risk gate: PASS\n'
printf 'Report: %s\n' "$REPORT_FILE"
