import Foundation

/// 应用页业务抽屉的种类 —— 只收录曾经互相抢过呈现层的那几张。
///
/// 导入抽屉 / 账号选择抽屉有各自独立的呈现路径，不在本仲裁范围内。
enum ArbitratedSheet: Equatable, Sendable {
    /// 单签 / 单续签的操作抽屉（`AppSigningSheet`，内含进度与结果）。
    case operation
    /// 已安装应用的操作抽屉（`InstalledAppActionSheet`）。
    case installedAction
    /// 批量续签抽屉（`BatchRefreshView`，进行中与结果共用一张）。
    case batchResult
    /// 应用详情抽屉（`AppDetailView`）。
    case detail
}

/// 仲裁器对一次「请求呈现」的裁决。
enum SheetArbitrationAction: Equatable, Sendable {
    /// 什么都不用做：已经在台上，或请求已登记为待呈现。
    case none
    /// 现在就可以呈现这张抽屉（它已经是台上那张）。
    case present(ArbitratedSheet)
    /// 先关掉当前抽屉；等它的关闭完成事件回来，待呈现的那张才上台。
    case dismissCurrentThenPresentPending
}

/// 抽屉呈现仲裁状态机（纯逻辑、无 SwiftUI 依赖）。
///
/// ## 为什么需要它
///
/// 旧实现靠三样拼凑交接：关抽屉后硬等 250ms、批量结果出现时在 `onChange`
/// 里强清其他抽屉状态、绑定层门禁事后拦截 —— 边缘时序（后台结果撞上正开着的
/// 操作抽屉、通知冷启动呈现）下仍会出现两张抽屉同场、一闪而过、或呈现状态
/// 已置位却没有真正弹出的死锁。
///
/// 本状态机把规则收成一条：**同一时刻只许一张抽屉在场；交接必须串行 ——
/// 先请求关闭当前抽屉，收到它的关闭完成事件（`sheetDidDismiss`）后，
/// 待呈现的那张才被裁决为可以上台。** 没有延时，没有事后强清。
///
/// 使用约定（呈现层负责执行裁决）：
/// - 想呈现一张抽屉先 `request`；裁决 `.present` 才把对应状态置为呈现，
///   裁决 `.dismissCurrentThenPresentPending` 就关掉当前抽屉的状态、
///   **不要**同时置新抽屉的呈现状态。
/// - 每张抽屉的 `onDismiss` 必须回调用 `sheetDidDismiss`；它返回
///   `.present(pending)` 时呈现层才置待呈现抽屉的呈现状态。
struct SheetArbiter: Equatable, Sendable {
    /// 当前在场的抽屉（已呈现，或正在关闭交接中 —— 关闭完成前仍算在场）。
    private(set) var current: ArbitratedSheet?
    /// 已登记、等当前抽屉关闭完成后上台的抽屉。
    private(set) var pending: ArbitratedSheet?

    init(current: ArbitratedSheet? = nil, pending: ArbitratedSheet? = nil) {
        self.current = current
        self.pending = pending
    }

    var isIdle: Bool { current == nil && pending == nil }

    /// 这张抽屉现在是否被允许真正呈现（绑定层门禁只读它）。
    func allowsPresentation(of sheet: ArbitratedSheet) -> Bool {
        current == sheet
    }

    /// 登记一次呈现请求。
    ///
    /// - 台上无人：请求者立即上台。
    /// - 请求者已在台上：无事发生（重复请求不产生第二次呈现）。
    /// - 台上有人：请求者登记为待呈现，裁决关闭当前抽屉；
    ///   已有待呈现者时以最新请求为准（呈现意图永远来自最近一次用户/系统动作）。
    @discardableResult
    mutating func request(_ sheet: ArbitratedSheet) -> SheetArbitrationAction {
        if current == sheet {
            return .none
        }
        guard current != nil else {
            current = sheet
            return .present(sheet)
        }
        pending = sheet
        return .dismissCurrentThenPresentPending
    }

    /// 抽屉关闭完成事件（呈现层 `onDismiss` 回调）。
    ///
    /// 只有当前在场抽屉的关闭事件有效；过时抽屉的迟到事件直接忽略，
    /// 不能把后来上台的抽屉误清掉。关闭完成后待呈现者立即上台。
    @discardableResult
    mutating func sheetDidDismiss(_ sheet: ArbitratedSheet) -> SheetArbitrationAction {
        guard sheet == current else { return .none }
        current = nil
        guard let next = pending else { return .none }
        pending = nil
        current = next
        return .present(next)
    }

    /// 撤销一个尚未上台的待呈现请求（例如它的数据已被作废）。
    mutating func cancelPending(_ sheet: ArbitratedSheet) {
        if pending == sheet {
            pending = nil
        }
    }
}

/// 持久化批量结果在「恢复」这一步应该走哪条路（纯判据）。
///
/// ## 冷启动死锁的根因（log-47，2026-10-22）
///
/// 后台快捷指令续签完成后，载荷刚持久化（SEAL-RENEW-023），**同一个后台
/// 进程内**的某次 `load()` 就把结果恢复进会话并置位呈现标志
/// （SEAL-RENEW-024 与 023 同一秒）—— 呈现发生在没有呈现层的时刻，
/// SwiftUI 不会补弹；用户随后点通知进前台时，会话与呈现标志都停在
/// 「已呈现」的假状态里：结果抽屉不弹，列表点按又被「有已结算结果待
/// 呈现」的优先逻辑吞掉（见 `AppsRootView.openApp`），形成死锁。
///
/// 修法：恢复与呈现解耦 —— 非呈现调用方（启动 `load()`、队列恢复）
/// 只把结果**登记**为待呈现，绝不置呈现标志、不写 024；
/// 只有呈现层在宿主就绪且 App 处于 active 时显式授权的那一次调用，
/// 才允许真正恢复并呈现。已在本进程呈现过的会话被新载荷更新时
/// （Seal 结算改写了同一份载荷）只原地更新内容，那不是一次新呈现。
enum BatchResultRestoreRoute: Equatable, Sendable {
    /// 有载荷，但现在既不能呈现也不需要登记（已有现场会话 / 已呈现且载荷未变）。
    case ignore
    /// 只登记「有待呈现结果」，不动会话、不置呈现标志、不写恢复日志。
    case registerAwaitingPresentation
    /// 呈现层已授权：恢复进会话并置呈现标志（写 SEAL-RENEW-024）。
    case restoreForPresentation
    /// 已呈现会话的载荷被结算改写：原地更新会话内容，保留抽屉身份。
    case updatePresentedSession
}

enum BatchResultRestorePolicy {
    static func route(
        hasPayload: Bool,
        presentationAuthorized: Bool,
        hasPresentedSession: Bool,
        payloadFingerprintChanged: Bool,
        hasActiveBatchTask: Bool,
        hasLiveUnrestoredSession: Bool
    ) -> BatchResultRestoreRoute {
        guard hasPayload, hasActiveBatchTask == false else { return .ignore }
        if hasPresentedSession {
            return payloadFingerprintChanged ? .updatePresentedSession : .ignore
        }
        if hasLiveUnrestoredSession {
            return .ignore
        }
        return presentationAuthorized
            ? .restoreForPresentation
            : .registerAwaitingPresentation
    }
}
