import UIKit
import Photos
import PhotosUI
import CryptoKit

// ===== 实况（Live Photos）App 端 =====
// 统一对接口径（与后端并行分支一致）：
// - 静态图仍走现行 /beary/api/images/upload（dataUrl + 缩略图）；实况视频
//   随静态图一起传，附带 videoDataUrl（mov，video/quicktime），后端把视频存
//   R2，key = 静态图 key + "_live"，回包多一个 live_key。
// - 日记新建/编辑 payload 在 images 数组之外加 live_videos：{"<静态图key>": "<视频key>"}，
//   无实况的图不出现在映射里；读接口 entry.live_videos 同样是这个映射，旧纯
//   静态图日记 live_videos 为空/缺失，按无实况处理。
// - 视频访问权限与静态图同口径：同一 /beary/api/images/<key> 端口、同一会话
//   cookie，私密图仅作者与 id=1 可看，公开图按现行公开口径（服务端判定，
//   App 端不另做权限判断，不把视频 URL 拼到别处）。
// 显示口径：卡片/详情/灯箱里实况图平时仍显示原静态帧（原 UIImageView 一字
// 不动），本覆盖层只在实况就绪后才显现（其静态帧即服务端原图，与槽位图同
// 内容），长按播实况；点图进灯箱等原有交互不动（长按后的抬手点按由调用方
// 凭 suppressTapUntil 压住一次，见各调用点）。

enum BearyLivePhoto {
    /// App 端实况视频单条上限：10MB（原始 mov 大小，base64 之前算）。
    /// iOS 实况视频通常 2–5MB，10MB 覆盖绝大多数；超限在选图时直接拒收
    /// （toast 说明、不进图片条），不静默降级为静态图。
    static let maxVideoBytes = 10 * 1024 * 1024

    static func videoDataURL(_ data: Data) -> String {
        return "data:video/quicktime;base64," + data.base64EncodedString()
    }
}

extension BearyImageURLs {
    /// 实况视频地址：liveKey 本身就是完整 R2 key（静态图 key + "_live"），
    /// 走与静态图同一端口，不拼 thumb 后缀。
    static func liveVideoURL(liveKey: String) -> URL? {
        return imageURL(key: liveKey, thumb: false)
    }
}

/// 实况加载：视频与静态原图各走一次服务端下载（与图片加载同款会话 +
/// 重定向守门 + 会话 cookie），落系统 caches 目录按账号分桶，内存再缓存
/// 一份 PHLivePhoto 供卡片复用滚动时复用；任一步失败返回 nil，调用方只
/// 显示静态帧，不亮失败态（实况是静态图之上的加分项，失败不破坏原图）。
final class BearyLivePhotoLoader {
    static let shared = BearyLivePhotoLoader()
    private let cache = NSCache<NSString, PHLivePhoto>()
    private let session: URLSession

    /// 磁盘读 + TTL/上限 sweep 只走这里，不占主线程（原实现在调用线程同步读盘，
    /// 调用方是主线程的卡片 configure，实况 mov 可达 10MB，首帧可卡）。
    private static let diskQueue = DispatchQueue(label: "com.beary.live-disk", qos: .userInitiated)
    /// 磁盘缓存 TTL 24 小时：与图片桶（BearyImageLoader）同款口径。
    /// 实况视频与静态图同一可见性口径：转私密后旧盘缓存至多再活 24 小时，
    /// 之后强制走网络、服务端按最新可见性判定，不无限期可读。
    private static let diskCacheMaxAge: TimeInterval = 24 * 3600
    /// 每账号桶磁盘上限 200MB：与图片桶同款；超了按修改时间删最旧文件直至回落。
    private static let diskCacheCapBytes: Int64 = 200 * 1024 * 1024

    private let stateLock = NSLock()
    /// 桶代次：load() 起始桶与上次不同即 +1，旧桶在途任务取消、旧桶回包丢弃。
    /// 内存键本身也含桶（见 memoryKey），切号后旧号条目即不可达。
    private var generation = 0
    private var activeBucket: String?
    private var inFlightTasks: [URLSessionDataTask] = []
    private var diskCacheTotals: [String: Int64] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        // 审计-性能：只关 URLCache，不改 ephemeral。ephemeral 会丢共享
        // cookie 存储，私密实况视频将 401；图片加载器同款口径（default +
        // urlCache=nil）：URLCache 按 URL 裸键、不分账号，私密字节一旦
        // 进共享缓存，换号后仍可能被命中而不走服务端可见性判定，故关掉；
        // 本加载器自有按账号分桶的磁盘缓存，URLCache 层纯属多余。
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config, delegate: BearyImageRedirectGuard.shared, delegateQueue: nil)
        // PHLivePhoto 内存条目偏大（视频），NSCache 仍会在内存压力下自动逐出；
        // countLimit 只作后备上限，不作日常淘汰依据。
        cache.countLimit = 20
    }

    private func bucket() -> String {
        if let id = BearyImageLoader.shared.currentAccountId {
            return String(id)
        }
        return "guest"
    }

    private func memoryKey(bucket: String, liveKey: String) -> NSString {
        return "\(bucket)|\(liveKey)" as NSString
    }

    private func fileURL(key: String, ext: String, bucket: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + "." + ext
        let dir = caches.appendingPathComponent("BearyLiveCache").appendingPathComponent(bucket, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent(name)
    }

    private func currentGeneration() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    private func isCurrentGeneration(_ gen: Int) -> Bool {
        return gen == currentGeneration()
    }

    /// 退出/401 清态：清该账号实况内存 + 磁盘桶（SessionManager 退出路径调用，
    /// 与图片桶 purgeAccount 同口径；切换账号不走这里，旧桶保留、切回可复用）。
    /// 第七轮审计 06：先推进代次、取消在途下载，再清内存、删目录。代次屏障使
    /// 删除前已在途、删除后才到写盘点的旧下载在完成回调守卫处即被丢弃，不再
    /// 调 writeDisk 重新创建刚删除的目录；取消任务使仍在途的网络任务不再跑
    /// 完整个回调链。只删目录不做这两件，迟到回包会把缓存目录重新建回来
    /// （writeDisk 经 fileURL 先 createDirectory 再写盘）。
    func purgeAccount(_ id: Int) {
        stateLock.lock()
        generation += 1
        let stale = inFlightTasks
        inFlightTasks.removeAll()
        stateLock.unlock()
        stale.forEach { $0.cancel() }
        cache.removeAllObjects()
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("BearyLiveCache").appendingPathComponent("\(id)")
        try? FileManager.default.removeItem(at: dir)
        stateLock.lock()
        diskCacheTotals["\(id)"] = nil
        stateLock.unlock()
    }

    private func diskData(key: String, ext: String, bucket: String) -> Data? {
        guard let file = fileURL(key: key, ext: ext, bucket: bucket) else { return nil }
        if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
           let mtime = values.contentModificationDate,
           Date().timeIntervalSince(mtime) > Self.diskCacheMaxAge {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        return data
    }

    /// 第七轮审计 06：写盘前再验一次代次——下载完成回调的守卫与真正落盘之间
    /// 仍有一道窗口（purge 可能正好夹在中间），这里是最后一道门；代次已变
    /// 即弃写，不重新创建刚删除的缓存目录。
    private func writeDisk(data: Data, key: String, ext: String, bucket: String, generation gen: Int) {
        guard isCurrentGeneration(gen) else { return }
        guard let file = fileURL(key: key, ext: ext, bucket: bucket) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? data.write(to: file, options: .atomic)
        let newSize = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        enforceDiskCacheCap(bucket: bucket, writtenDelta: newSize - oldSize)
    }

    private func enforceDiskCacheCap(bucket: String, writtenDelta: Int64) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("BearyLiveCache").appendingPathComponent(bucket)
        stateLock.lock()
        defer { stateLock.unlock() }
        var tracked: Int64
        if let known = diskCacheTotals[bucket] {
            tracked = known + writtenDelta
            diskCacheTotals[bucket] = tracked
            guard tracked > Self.diskCacheCapBytes else { return }
        } else {
            // 本进程首写、累计值未知：置为越限值，迫使本次即枚举校准一次。
            tracked = Self.diskCacheCapBytes + 1
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            diskCacheTotals[bucket] = tracked
            return
        }
        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        var total: Int64 = 0
        for name in names {
            let url = dir.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let mtime = values.contentModificationDate else { continue }
            entries.append((url: url, size: Int64(size), mtime: mtime))
            total += Int64(size)
        }
        guard total > Self.diskCacheCapBytes else {
            diskCacheTotals[bucket] = total
            return
        }
        entries.sort { $0.mtime < $1.mtime }
        for entry in entries {
            if total <= Self.diskCacheCapBytes { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
        diskCacheTotals[bucket] = total
    }

    private func untrackTask(_ task: URLSessionDataTask) {
        stateLock.lock()
        inFlightTasks.removeAll { $0 === task }
        stateLock.unlock()
    }

    private func download(url: URL, key: String, ext: String, bucket: String, generation gen: Int, completion: @escaping (Data?) -> Void) {
        var task: URLSessionDataTask?
        task = session.dataTask(with: url) { [weak self] data, response, _ in
            if let task = task { self?.untrackTask(task) }
            guard let self = self, self.isCurrentGeneration(gen),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data = data, !data.isEmpty else {
                completion(nil)
                return
            }
            self.writeDisk(data: data, key: key, ext: ext, bucket: bucket, generation: gen)
            completion(data)
        }
        guard let task = task else {
            completion(nil)
            return
        }
        stateLock.lock()
        inFlightTasks.append(task)
        stateLock.unlock()
        task.resume()
    }

    func load(staticKey: String, liveKey: String, contentMode: PHImageContentMode, completion: @escaping (PHLivePhoto?) -> Void) {
        // 桶在 load 起始固定：整条链路（磁盘读 / 网络写盘 / 内存键）都用它，
        // 切号夹在请求与回包之间时不再写进新号桶；桶变了即取消旧桶在途任务。
        let bucket = self.bucket()
        stateLock.lock()
        if activeBucket != bucket {
            activeBucket = bucket
            generation += 1
            let stale = inFlightTasks
            inFlightTasks.removeAll()
            stateLock.unlock()
            stale.forEach { $0.cancel() }
        } else {
            stateLock.unlock()
        }
        let gen = currentGeneration()
        if let cached = cache.object(forKey: memoryKey(bucket: bucket, liveKey: liveKey)) {
            completion(cached)
            return
        }
        guard let videoURL = BearyImageURLs.liveVideoURL(liveKey: liveKey),
              let stillURL = BearyImageURLs.imageURL(key: staticKey, thumb: false) else {
            completion(nil)
            return
        }
        Self.diskQueue.async { [weak self] in
            guard let self = self, self.isCurrentGeneration(gen) else {
                // 第七轮审计 07：过期任务也要结束回调——直接 return 会丢掉
                // completion，BearyLivePhotoView 的 currentLiveKey 永久残留，
                // 同一张图再 configure 会被「同 key 不重复加载」跳过，实况
                // 永远不再出现；主线程回 nil，让视图清掉失败态。
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if let videoData = self.diskData(key: liveKey, ext: "mov", bucket: bucket),
               let stillData = self.diskData(key: staticKey, ext: "jpg", bucket: bucket) {
                // 磁盘双命中：数据已落盘，build 只凭文件 URL 组装，不再读盘。
                _ = videoData
                self.buildLivePhoto(stillData: stillData, bucket: bucket, liveKey: liveKey, staticKey: staticKey, generation: gen, contentMode: contentMode, completion: completion)
                return
            }
            self.download(url: videoURL, key: liveKey, ext: "mov", bucket: bucket, generation: gen) { [weak self] videoData in
                guard let self = self, videoData != nil, self.isCurrentGeneration(gen) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.download(url: stillURL, key: staticKey, ext: "jpg", bucket: bucket, generation: gen) { stillData in
                    guard let stillData = stillData, self.isCurrentGeneration(gen) else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    self.buildLivePhoto(stillData: stillData, bucket: bucket, liveKey: liveKey, staticKey: staticKey, generation: gen, contentMode: contentMode, completion: completion)
                }
            }
        }
    }

    private func buildLivePhoto(stillData: Data, bucket: String, liveKey: String, staticKey: String, generation gen: Int, contentMode: PHImageContentMode, completion: @escaping (PHLivePhoto?) -> Void) {
        guard let videoFile = self.fileURL(key: liveKey, ext: "mov", bucket: bucket),
              let stillFile = self.fileURL(key: staticKey, ext: "jpg", bucket: bucket),
              FileManager.default.fileExists(atPath: videoFile.path),
              FileManager.default.fileExists(atPath: stillFile.path),
              let placeholder = UIImage(data: stillData) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: placeholder.size.width * scale, height: placeholder.size.height * scale)
        _ = PHLivePhoto.request(
            withResourceFileURLs: [stillFile, videoFile],
            placeholderImage: placeholder,
            targetSize: targetSize,
            contentMode: contentMode
        ) { [weak self] photo, _ in
            DispatchQueue.main.async {
                // 桶已切换的回包直接丢弃、不进新桶内存缓存（视图层 token 同样守门）。
                guard let photo = photo, let self = self, self.isCurrentGeneration(gen) else {
                    completion(nil)
                    return
                }
                self.cache.setObject(photo, forKey: self.memoryKey(bucket: bucket, liveKey: liveKey))
                completion(photo)
            }
        }
    }
}

/// 实况覆盖层：盖在原 UIImageView 槽位之上，平时隐藏（原静态帧可见），
/// 实况就绪后显现，长按由调用方调 startPlayback；自身不接任何手势，
/// 点按/滑动/缩放等原有交互一律透传给下层视图。
final class BearyLivePhotoView: UIView {
    private let liveView = PHLivePhotoView()
    private let photoContentMode: PHImageContentMode
    private var currentLiveKey: String?
    private var loadToken = 0

    /// 长按播完抬手时，调用方凭此压住紧随其后的那次点按（防长按变进灯箱）。
    var suppressTapUntil: Date?

    var hasLivePhoto: Bool {
        return liveView.livePhoto != nil
    }

    init(contentMode: PHImageContentMode) {
        self.photoContentMode = contentMode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isHidden = true
        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.isUserInteractionEnabled = false
        liveView.contentMode = (contentMode == .aspectFill) ? .scaleAspectFill : .scaleAspectFit
        liveView.backgroundColor = .clear
        addSubview(liveView)
        NSLayoutConstraint.activate([
            liveView.topAnchor.constraint(equalTo: topAnchor),
            liveView.bottomAnchor.constraint(equalTo: bottomAnchor),
            liveView.leadingAnchor.constraint(equalTo: leadingAnchor),
            liveView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// staticKey/liveKey 任一为空即按无实况处理（旧静态图、非实况图走这里）。
    /// 同一 liveKey 重复调用不重复加载；换 key 时旧加载回包凭 token 丢弃。
    func configure(staticKey: String?, liveKey: String?) {
        guard let staticKey = staticKey, !staticKey.isEmpty,
              let liveKey = liveKey, !liveKey.isEmpty else {
            clear()
            return
        }
        if liveKey == currentLiveKey {
            return
        }
        clear()
        currentLiveKey = liveKey
        loadToken += 1
        let token = loadToken
        BearyLivePhotoLoader.shared.load(staticKey: staticKey, liveKey: liveKey, contentMode: photoContentMode) { [weak self] photo in
            guard let self = self, token == self.loadToken, self.currentLiveKey == liveKey else { return }
            if let photo = photo {
                self.liveView.livePhoto = photo
                self.isHidden = false
            } else {
                // 失败不留 currentLiveKey：否则下次同 key 再 configure 会命中
                // 「同 key 不重复加载」直接 return，弱网抖动后实况永远不再出现，
                // 只能靠滑走复用清掉；清掉后下次 configure 重新加载（加载中
                // 的同 key 调用仍由 token＋currentLiveKey 守门，不会重复拉）。
                self.currentLiveKey = nil
                self.isHidden = true
            }
        }
    }

    func clear() {
        loadToken += 1
        currentLiveKey = nil
        liveView.livePhoto = nil
        isHidden = true
        suppressTapUntil = nil
    }

    func startPlayback() {
        if liveView.livePhoto != nil {
            liveView.startPlayback(with: .full)
        }
    }
}
