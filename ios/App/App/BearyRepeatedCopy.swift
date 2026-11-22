import Foundation

/// 共享文案表：全站重复整句文案的单点定义，调用点只引语义 key。
/// 文案本身是 Li 定的，不改字、只收口。
///
/// 本文件零依赖（只有 String 常量），特意独立成文件：App target 与
/// BearyCoreTests target 都编它——测试包只编 22 个生产文件，
/// BearyNativeCommon.swift 不在其中，表放那边会让测试包里引用它的
/// BearyDiaryPin.swift 编不过（#2164 test 红实证）。以后往表里加条目
/// 不用改 target；但别往本文件加任何跨文件引用，保持零依赖。
/// 语义 key、中文作值；#2015 多语言地基合入后，由合入协调员变基适配
/// 目录（catalog）机制，本支不另发明 key 体系。
enum BearyRepeatedCopy {
    /// 第十轮审计 dsh II-7：三句重复短句抽常量（各 4 处），文案本身不动，只收一处定义。
    /// 变基注：第四句“编辑（已超 15 分钟不可编辑）”的四处菜单项已随 main 的编辑永久可改
    /// （15 分钟门控删除）消失，该常量不再收录。
    /// 注释里的同形短句（盲盒 flow :11/:1314/:1566）不是字面量引用，不动。
    /// 盲盒今日已换过：占位＋Toast＋两处错误文案映射共 4 处。
    static let blindBoxAlreadySwappedToday = "今日已换过 1 次，明天再来"
    /// 盲盒加载失败：两处错误文案映射的默认分支＋404 分支共 4 处。
    static let blindBoxLoadFailed = "盲盒暂时无法加载，请稍后重试"
    /// 公开失败且原日记恢复失败：详情／广场／个人页／时间线四处 Toast 共 4 处。
    static let publishFailedRestoreFailed = "公开失败，原日记恢复失败，请检查"

    // MARK: - 整句 toast／错误／空态文案（2026-11-22 Li 定收口）
    // 同一整句散在多文件各写一份，改一处漏一处；此处单点定义，调用点只引 key。
    // 不收：短词按钮文案（重试／返回／关闭／删除／取消）；displayTitle 的
    // fallback（“无标题日记”vs“一篇日记”，按 fix/display-title-shared 收）；
    // 错误码映射表里三句（“正文最多 2000 字”等，按 fix/error-message-table-shared 收）。
    /// 网络不稳定：盲盒／编辑器／广场／邀请／登录／九宫格／设置／SceneDelegate 共 13 处。
    static let networkUnstable = "网络不稳定，请稍后再试"
    /// 引用的日记已删除：编辑器／详情／卡片／个人页／时间线共 13 处。
    static let quotedEntryDeleted = "引用的日记已删除"
    /// 请先登录：置顶／编辑资料／广场／邀请／通知／个人页／设置／时间线／回收站／SceneDelegate 共 14 处。
    static let loginRequired = "请先登录"
    /// 操作失败：详情／广场／通知／个人页／设置子页／快照对比／快照列表／标签共 12 处。
    static let operationFailedRetry = "操作失败，请重试"
    /// 操作太频繁：详情／置顶／广场／个人页／时间线／许愿墙共 11 处。
    static let tooFrequentRetryLater = "操作太频繁，请稍后再试"
    /// 登录已过期：盲盒／编辑资料／设置／SceneDelegate 共 8 处。
    static let sessionExpiredRelogin = "登录已过期，请重新登录"
    /// 原日记公开失败：编辑器／详情／广场／个人页／发布中心／时间线共 7 处。
    static let originalPublishFailedRetry = "原日记公开失败，请重试"
    /// 加载失败：盲盒／编辑资料／邀请／个人页／设置／标签／时间线共 7 处。
    static let loadFailedRetry = "加载失败，请重试"
    /// 删除失败：私信会话／草稿箱／表情选择器／通知／回收站／SceneDelegate 共 7 处。
    static let deleteFailedRetry = "删除失败，请重试"
    /// 加载中：私信／地图／好友／邀请／Plus 页／个人页／设置子页／许愿墙共 13 处。
    static let loading = "加载中…"
    /// 发布中：编辑器 11 处（含 6 处发布分支 toast 与 5 处保存中／发布中三元）＋草稿箱 3 处。
    static let publishing = "发布中…"
    /// 空态：还没有公开的日记（广场 2 处、个人页 2 处）。
    static let emptyNoPublicEntries = "还没有公开的日记"
    /// 空态：还没有赞过的日记（编辑器引用面板 1 处、个人页 2 处）。
    static let emptyNoLikedEntries = "还没有赞过的日记"
    /// 空态：还没有收藏的日记（编辑器引用面板 1 处、个人页 2 处）。
    static let emptyNoSavedEntries = "还没有收藏的日记"
}
