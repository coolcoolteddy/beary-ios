import Foundation

/// 搜索防抖共用小件：invalidate＋重排期＋weak self。
///
/// 两处 0.25s 搜索防抖（全站搜索 BearySearchViewController、选人搜索
/// BearyComposerPickers）共用计时 plumbing，各留自己的守卫与查询调用：
/// 主搜索的组词守卫与序号取消、选人搜索的基础防抖都在调用方，不进这里。
/// 间隔保持 0.25s 不变，不改手感；其余 Timer（草稿／撤销／复制等）不是
/// 搜索防抖，不动。
final class BearyDebouncer {
    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 0.25) {
        self.interval = interval
    }

    /// 取消待发的一次，再按 interval 重新排期；到期只跑一次。
    func schedule(_ action: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.timer = nil
            action()
        }
    }

    /// 取消待发的一次（离页／清空／回车立即发时用）。
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
