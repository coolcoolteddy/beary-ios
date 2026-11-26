import UIKit

// ===== 行操作按钮查表 =====
// 草稿箱与回收站共用的小泛型查表：行内按钮 ↔ 对应条目的登记表。
// 两页原先各写一套 (button, value) 元组数组，按钮反查与按 id 移除逐字同形，抽到这里。
// 删除／恢复／丢失／重试／彻底删除各动作的处理（点按回调、busy 守卫、确认框、
// 撤销与写盘）各留自己的，本表只管登记与反查；卡片行本身的位置登记
// （cardEntries，插位／挪位／按下标取）不在此表。
// 部署目标 iOS 15.0、Swift 5.0——不用 if-let 简写。

/// 行操作按钮查表：登记（按钮，值），按按钮反查值、按 id 找按钮／移除。
/// id 由调用方以 KeyPath 指定（草稿 `\.draftId`、回收站 `\.entryIdentifier`）。
struct BearyRowButtonLookup<Value> {
    private var entries: [(button: UIButton, value: Value)] = []
    private let idKeyPath: KeyPath<Value, String>

    init(id: KeyPath<Value, String>) {
        self.idKeyPath = id
    }

    mutating func append(button: UIButton, value: Value) {
        entries.append((button: button, value: value))
    }

    /// 清空登记（全量重渲时用）。
    mutating func removeAll() {
        entries.removeAll()
    }

    /// 按 id 移除该条目的全部登记。
    mutating func removeAll(id: String) {
        entries.removeAll { $0.value[keyPath: self.idKeyPath] == id }
    }

    /// 按值谓词移除（与 Array.removeAll(where:) 同义，如清无 id 的旧行登记）。
    mutating func removeAll(where shouldRemove: (Value) -> Bool) {
        entries.removeAll { shouldRemove($0.value) }
    }

    /// 点按处理：按钮 → 值（身份比对；回收站原先写 `==`，UIButton 未覆写
    /// isEqual，与 `===` 同为身份比对）。
    func value(for button: UIButton) -> Value? {
        entries.first(where: { $0.button === button })?.value
    }

    /// 按 id 找按钮（如左滑拖动进删、左滑菜单走按钮路径）。
    func button(forID id: String) -> UIButton? {
        return entries.first(where: { $0.value[keyPath: self.idKeyPath] == id })?.button
    }
}

extension BearyRowButtonLookup: Sequence {
    func makeIterator() -> IndexingIterator<[(button: UIButton, value: Value)]> {
        entries.makeIterator()
    }
}
