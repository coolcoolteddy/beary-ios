import UIKit

// MARK: - 存储空间用量（体验检查第 8 项）
//
// 设置页“存储空间”入口的三类用量只读统计与清理口径：
// ① 图片缓存（Caches，可清）：BearyImageCache/<桶> 与 BearyLiveCache/<桶>
//    （桶 = 当前账号 id，未登录为 guest；与 BearyImageLoader /
//    BearyLivePhotoLoader 的落盘口径一致）。
// ② 日记与广场快照（ApplicationSupport，可清、可重同步）：服务端派生
//    的本地快照，与 SessionManager 退出清理清单（purgeLocalSnapshots）
//    同范围——广场/正在关注/时间线/个人页/统计/相册/通知/许愿墙/私信会话
//    /详情快照、日记同步桶（含 staging/.bak/状态文件）、回收站桶、月历快照。
//    清理复用各缓存既有的 purge，不直接删文件。
// ③ 草稿与私信（ApplicationSupport，永不清、仅展示）：草稿文字与图片、
//    私信整库与待发送（含损坏备份）；退出登录时同样刻意保留，见
//    SessionManager.signOutLocally。
// 用量只做展示：清理走各所有者既有的 purge 函数，即使某文件名前缀
// 未来改名，至多用量数字漏计，绝不会误删。
enum BearyStorageUsage {

    struct Sizes {
        var imageCache: Int64 = 0
        var snapshots: Int64 = 0
        var draftsAndDMs: Int64 = 0
        var total: Int64 { imageCache + snapshots + draftsAndDMs }
    }

    /// 文件大小文案（与系统“用量”口径一致；0 直接显 0 KB，不显 Zero KB）。
    static func formatted(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 后台线程枚举、前台回调；账号切换中途的旧回包由调用方自行丢弃
    ///（本页只在 viewWillAppear 与清理后重算，生命周期内账号不变）。
    static func compute(accountId: Int?, completion: @escaping (Sizes) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let sizes = computeSync(accountId: accountId)
            DispatchQueue.main.async { completion(sizes) }
        }
    }

    private static func computeSync(accountId: Int?) -> Sizes {
        var sizes = Sizes()
        let fileManager = FileManager.default
        let bucket = accountId.map(String.init) ?? "guest"
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            // ① 图片缓存：只计当前账号桶（登录态与游客态各有各的桶，不跨账号）。
            sizes.imageCache += sizeOfItem(at: caches.appendingPathComponent("BearyImageCache").appendingPathComponent(bucket))
            sizes.imageCache += sizeOfItem(at: caches.appendingPathComponent("BearyLiveCache").appendingPathComponent(bucket))
        }
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let names = try? fileManager.contentsOfDirectory(atPath: support.path) else {
            return sizes
        }
        // ② 快照：字符串桶名（登录为 id、游客为 guest）的文件名前缀。
        // 文件名前缀与各缓存 fileURL 口径一致（见 BearyFeedViewController、
        // BearyTimelineViewController、BearyProfileViewController、
        // BearyProfilePhotosViewController、BearyNotificationsViewController、
        // BearyWishWallViewController、BearyDMConversationsViewController、
        // BearyDetailViewController）。
        let snapshotFileNames = [
            "beary_feed_cache_\(bucket).json",
            "beary_feed_cache_\(bucket)-following.json",
            "beary_timeline_cache_\(bucket).json",
            "beary_profile_cache_\(bucket).json",
            "beary_profile_stats_cache_\(bucket).json",
            "beary_profile_photos_cache_\(bucket).json",
            "beary_notification_cache_\(bucket).json",
            "beary_wish_wall_cache_\(bucket).json",
            "beary_dm_conversations_cache_\(bucket).json",
            "beary_detail_cache_\(bucket).index.json",
        ]
        let snapshotFilePrefix = "beary_detail_cache_\(bucket)_"
        // ② 快照：仅登录账号有的整型桶（日记同步、回收站、月历；游客无此三类落盘）。
        var snapshotNames: Set<String> = Set(snapshotFileNames)
        if let id = accountId {
            snapshotNames.insert("beary_entry_sync_\(id)")
            snapshotNames.insert("beary_entry_sync_\(id).staging")
            snapshotNames.insert("beary_entry_sync_\(id).bak")
            snapshotNames.insert("beary_entry_sync_\(id)_state.json")
            snapshotNames.insert("beary_trash_sync_\(id)")
            snapshotNames.insert("beary_trash_sync_\(id)_state.json")
            snapshotNames.insert("beary_calendar_snapshot_\(id)")
        }
        // ③ 草稿与私信：仅登录账号有（游客读写均为空，见 BearyDraftFiles 与 BearyDMStore）。
        var draftNames: Set<String> = []
        var draftPrefixes: [String] = []
        if let id = accountId {
            draftNames.insert("beary_draft_v3_\(id).json")
            draftNames.insert("beary_draft_images_\(id)")
            draftNames.insert("beary_dm_\(id).json")
            draftNames.insert("beary_dm_pending_\(id).json")
            // 损坏备份：原文件不动、另存时间戳 .bak（见 BearyDMStore）。
            draftPrefixes.append("beary_dm_\(id).json.corrupt-")
            draftPrefixes.append("beary_dm_pending_\(id).json.corrupt-")
        }
        for name in names {
            let url = support.appendingPathComponent(name)
            if snapshotNames.contains(name) || name.hasPrefix(snapshotFilePrefix) {
                sizes.snapshots += sizeOfItem(at: url)
            } else if draftNames.contains(name) || draftPrefixes.contains(where: { name.hasPrefix($0) }) {
                sizes.draftsAndDMs += sizeOfItem(at: url)
            }
        }
        return sizes
    }

    /// 单文件或目录（含子目录）的逻辑大小；不存在返回 0。
    private static func sizeOfItem(at url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        }
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for case let fileURL as URL in enumerator {
                if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                   values.isDirectory != true, let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }
}

// MARK: - 存储空间页（设置页子页壳：顶栏 + 滚动内容列）
//
// 三组卡片与入口行同口径：图片缓存／日记与广场快照各一行用量＋
// 一行“清理”；草稿与私信只一行用量＋一行说明（只存在本地，不清理）。
// 清理前弹底部弹窗二次确认（清诊断日志同款 BearyConfirmSheet）；
// 清理复用 SessionManager 的存储空间清理入口（与退出清理同一路径，
// 不碰保管库、不改登录态）；部分快照的删除走后台队列落盘，重算
// 延后 1 秒，免得把未删完的文件又计进来。
final class BearyStorageSettingsViewController: BearySettingsSubpageViewController {

    private var sizes = BearyStorageUsage.Sizes()
    private var isLoadingSizes = true
    private var isClearing = false

    private var totalLabel: UILabel?
    private var imageSizeLabel: UILabel?
    private var snapshotSizeLabel: UILabel?
    private var draftSizeLabel: UILabel?
    private var imageClearButton: UIButton?
    private var snapshotClearButton: UIButton?

    init() {
        super.init(title: "存储空间")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let total = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        total.text = "正在计算…"
        totalLabel = total
        contentStack.addArrangedSubview(total)

        let imageSize = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        imageSize.textAlignment = .right
        imageSizeLabel = imageSize
        let imageClear = makeClearButton(title: "清理图片缓存", action: #selector(clearImagesTapped))
        imageClearButton = imageClear
        contentStack.addArrangedSubview(makeGroupCard(title: "图片缓存", rows: [
            sizeRow(title: "图片缓存", sizeLabel: imageSize),
            buttonRow(imageClear),
        ]))

        let snapshotSize = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        snapshotSize.textAlignment = .right
        snapshotSizeLabel = snapshotSize
        let snapshotClear = makeClearButton(title: "清理日记与广场快照", action: #selector(clearSnapshotsTapped))
        snapshotClearButton = snapshotClear
        contentStack.addArrangedSubview(makeGroupCard(title: "日记与广场快照", rows: [
            sizeRow(title: "日记与广场快照", sizeLabel: snapshotSize),
            buttonRow(snapshotClear),
        ]))

        let draftSize = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray)
        draftSize.textAlignment = .right
        draftSizeLabel = draftSize
        let draftNote = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        draftNote.text = "只存在本地，不清理"
        contentStack.addArrangedSubview(makeGroupCard(title: "草稿与私信", rows: [
            sizeRow(title: "草稿与私信", sizeLabel: draftSize),
            draftNote,
        ]))
        refreshSizes()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshSizes()
    }

    private func sizeRow(title: String, sizeLabel: UILabel) -> UIView {
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabel.font = BearyDynamicType.smallBodyFont()
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sizeLabel.numberOfLines = 0
        let row = UIStackView(arrangedSubviews: [titleLabel, sizeLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    private func makeClearButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("清理", for: .normal)
        button.setTitleColor(BearyColors.destructiveText, for: .normal)
        button.titleLabel?.font = BearyDynamicType.smallBodyFont()
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.bearyAddPressFeedback()
        button.accessibilityLabel = title
        return button
    }

    private func buttonRow(_ button: UIButton) -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let row = UIStackView(arrangedSubviews: [button, spacer])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        return row
    }

    private func refreshSizes() {
        isLoadingSizes = true
        updateSizeLabels()
        BearyStorageUsage.compute(accountId: SessionManager.shared.currentUser?.id) { [weak self] sizes in
            guard let self = self else { return }
            self.sizes = sizes
            self.isLoadingSizes = false
            self.updateSizeLabels()
        }
    }

    private func updateSizeLabels() {
        if isLoadingSizes {
            totalLabel?.text = "正在计算…"
            imageSizeLabel?.text = "…"
            snapshotSizeLabel?.text = "…"
            draftSizeLabel?.text = "…"
            return
        }
        totalLabel?.text = "本机共占用 \(BearyStorageUsage.formatted(sizes.total))"
        imageSizeLabel?.text = BearyStorageUsage.formatted(sizes.imageCache)
        snapshotSizeLabel?.text = BearyStorageUsage.formatted(sizes.snapshots)
        draftSizeLabel?.text = BearyStorageUsage.formatted(sizes.draftsAndDMs)
    }

    private func updateClearButtons() {
        imageClearButton?.isEnabled = !isClearing
        snapshotClearButton?.isEnabled = !isClearing
    }

    @objc private func clearImagesTapped() {
        guard !isClearing else { return }
        BearyConfirmSheet.show(from: self, title: "清理图片缓存？", message: "清理后图片下次打开时重新加载。", actions: [
            BearyConfirmSheet.Action(title: "清理", style: .destructive, handler: { [weak self] in
                guard let self = self else { return }
                self.isClearing = true
                self.updateClearButtons()
                SessionManager.shared.clearImageCacheForCurrentAccount()
                self.didClear()
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    @objc private func clearSnapshotsTapped() {
        guard !isClearing else { return }
        BearyConfirmSheet.show(from: self, title: "清理日记与广场快照？", message: "清理后日记与广场下次打开时重新同步。", actions: [
            BearyConfirmSheet.Action(title: "清理", style: .destructive, handler: { [weak self] in
                guard let self = self else { return }
                self.isClearing = true
                self.updateClearButtons()
                SessionManager.shared.clearLocalSnapshotsForCurrentAccount()
                self.didClear()
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    private func didClear() {
        BearyToast.show(in: view, message: "已清理")
        // 部分快照的删除走后台队列落盘，立即重算可能仍计入未删完的文件，稍后再算一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.isClearing = false
            self.updateClearButtons()
            self.refreshSizes()
        }
    }
}
