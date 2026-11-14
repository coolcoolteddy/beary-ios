import UIKit
import Photos
import PhotosUI
import CryptoKit
import AVFoundation
import ImageIO

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
// 标识对齐（实况不播根因，2026-11-06）：服务端静帧是重编码后上传的 JPEG
// （BearyImagePrep.jpegData：UIGraphicsImageRenderer 重绘 + UIImage.jpegData），
// 元数据全丢，包括 Live Photo 配对用的 content identifier；视频是
// PHAssetResource 导出的原始 MOV，仍带原始标识。PHLivePhoto.request 要求
// 两者标识一致，否则返回 nil——组装前把视频的标识写进静帧 JPEG
// （MakerApple 字典 key "17"），再调 request；已上传的老图也因此能播，
// 不用重传、不改上传接口与服务端。

enum BearyLivePhoto {
    /// App 端实况视频单条上限：10MB（原始 mov 大小，base64 之前算）。
    /// iOS 实况视频通常 2–5MB，10MB 覆盖绝大多数；超限在选图时直接拒收
    /// （toast 说明、不进图片条），不静默降级为静态图。
    static let maxVideoBytes = 10 * 1024 * 1024

    static func videoDataURL(_ data: Data) -> String {
        return "data:video/quicktime;base64," + data.base64EncodedString()
    }

    /// R12C：上传前清掉实况视频里的 GPS 位置元数据。拍摄时开了定位，
    /// MOV 文件级 QuickTime 元数据里会带 com.apple.quicktime.location.ISO6709；
    /// 原始字节原样上传会把经纬度存上服务端，违背 Info.plist「日记本身只保存
    /// 地点文字、不保存经纬度」的承诺。只删位置项，其余元数据（尤其 Live Photo
    /// 配对用的 content-identifier）原样保留，否则下载回来组装不成实况。
    /// 无位置项时原样返回，不重写；剥离失败返回 nil，调用方按读取失败处理，
    /// 不把带 GPS 的原始字节发出。AVAssetExportSession passthrough 只重写
    /// 容器、不重编码音视频轨。
    static func videoDataByStrippingLocation(_ data: Data) -> Data? {
        let tmpDir = FileManager.default.temporaryDirectory
        let inputURL = tmpDir.appendingPathComponent("beary-live-strip-in-\(UUID().uuidString).mov")
        let outputURL = tmpDir.appendingPathComponent("beary-live-strip-out-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        do {
            try data.write(to: inputURL, options: .atomic)
        } catch {
            return nil
        }
        let asset = AVURLAsset(url: inputURL)
        let loadSemaphore = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["metadata"]) {
            loadSemaphore.signal()
        }
        guard loadSemaphore.wait(timeout: .now() + 5) == .success else { return nil }
        var loadError: NSError?
        guard asset.statusOfValue(forKey: "metadata", error: &loadError) == .loaded else { return nil }
        let kept = asset.metadata.filter { !isLocationMetadataItem($0) }
        guard kept.count != asset.metadata.count else {
            // 无位置项：原样返回，不重写（本轮新选的图走这里居多）。
            return data
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return nil }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.metadata = kept
        let exportSemaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously {
            exportSemaphore.signal()
        }
        guard exportSemaphore.wait(timeout: .now() + 30) == .success,
              session.status == .completed else {
            session.cancelExport()
            return nil
        }
        guard let stripped = try? Data(contentsOf: outputURL), !stripped.isEmpty else { return nil }
        return stripped
    }

    /// 位置元数据判定：文件级 QuickTime 位置项（ISO6709）与通用 location
    /// 键、旧式 udta ©xyz；其余元数据（content-identifier、创建时间等）
    /// 一律保留。
    private static func isLocationMetadataItem(_ item: AVMetadataItem) -> Bool {
        if let identifier = item.identifier?.rawValue,
           identifier == AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue {
            return true
        }
        if item.commonKey == .commonKeyLocation {
            return true
        }
        if let key = item.key as? String {
            if key == "©xyz" || key.lowercased().contains("location") {
                return true
            }
        }
        return false
    }
}

extension BearyImageURLs {
    /// 实况视频地址：liveKey 本身就是完整 R2 key（静态图 key + "_live"），
    /// 走与静态图同一端口，不拼 thumb 后缀。
    static func liveVideoURL(liveKey: String) -> URL? {
        return imageURL(key: liveKey, thumb: false)
    }
}

/// 实况加载：视频与静态原图各只下缺的那一份（磁盘命中即复用、不重复
/// 下载；双命中时视频只凭文件 URL 组装，不把整段 mov 读进内存），与
/// 图片加载同款会话 + 重定向守门 + 会话 cookie，落系统 caches 目录按
/// 账号分桶，内存再缓存一份 PHLivePhoto 供卡片复用滚动时复用；同一资
/// 源对的在途加载共用一份，不另发下载；任一步失败返回 nil，调用方只
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
    /// 按账号桶的下载代次（与图片加载器 BearyImageLoader.generations 同口径）：
    /// purgeAccount / 切桶只推进对应桶的代次，该桶在途写入（磁盘 / 内存 /
    /// 交付）在落点前复核代次，代次已变即弃写；其他桶在途任务不受影响。
    /// 内存键本身也含桶（见 memoryKey），切号后旧号条目即不可达。
    private var generations: [String: UInt64] = [:]
    private var activeBucket: String?
    /// 在途网络任务按桶记：切桶 / purge 只取消对应桶的任务，不掐断其他桶。
    private var inFlightTasks: [String: [URLSessionDataTask]] = [:]
    /// 同一资源对（桶 + liveKey）的在途加载共用一份：滚动复用或重复
    /// configure 撞上同一实况在途加载时只挂等待，不再另发下载，回包
    /// 分发给所有等待方（见 load 的 finish）。
    private final class InFlightLiveLoad {
        var completions: [(PHLivePhoto?) -> Void] = []
    }
    private var inFlightLoads: [NSString: InFlightLiveLoad] = [:]
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

    private func generation(for bucket: String) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generations[bucket] ?? 0
    }

    private func bumpGeneration(for bucket: String) {
        stateLock.lock()
        generations[bucket, default: 0] += 1
        stateLock.unlock()
    }

    private func isCurrentGeneration(_ gen: UInt64, bucket: String) -> Bool {
        return gen == generation(for: bucket)
    }

    /// 退出/401 清态：清该账号实况内存 + 磁盘桶（SessionManager 退出路径调用，
    /// 与图片桶 purgeAccount 同口径；切换账号不走这里，旧桶保留、切回可复用）。
    /// 顺序与图片桶一致：先推进该桶代次（删除前已在途、删除后才到写盘点的
    /// 旧写入凭代次弃写，不再把已删的私密实况写回来）、取消该桶在途下载，
    /// 再清内存、串行删目录、清累计字节。
    /// 第七轮审计 06：先推进代次、取消在途下载，再清内存、删目录。代次屏障使
    /// 删除前已在途、删除后才到写盘点的旧下载在完成回调守卫处即被丢弃，不再
    /// 调 writeDisk 重新创建刚删除的目录；取消任务使仍在途的网络任务不再跑
    /// 完整个回调链。只删目录不做这两件，迟到回包会把缓存目录重新建回来
    /// （writeDisk 经 fileURL 先 createDirectory 再写盘）。
    func purgeAccount(_ id: Int) {
        let bucket = "\(id)"
        bumpGeneration(for: bucket)
        stateLock.lock()
        let stale = inFlightTasks[bucket] ?? []
        inFlightTasks[bucket] = nil
        stateLock.unlock()
        stale.forEach { $0.cancel() }
        cache.removeAllObjects()
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent("BearyLiveCache").appendingPathComponent(bucket)
        try? FileManager.default.removeItem(at: dir)
        stateLock.lock()
        diskCacheTotals[bucket] = nil
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

    /// 只判文件在不在且未过期（TTL 过期即清掉、按缺失算），不读内容：
    /// 实况视频组装只凭文件 URL，命中时不必把整段 mov 读进内存。
    private func diskFileValid(key: String, ext: String, bucket: String) -> Bool {
        guard let file = fileURL(key: key, ext: ext, bucket: bucket) else { return false }
        if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
           let mtime = values.contentModificationDate,
           Date().timeIntervalSince(mtime) > Self.diskCacheMaxAge {
            try? FileManager.default.removeItem(at: file)
            return false
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, size > 0 else { return false }
        return true
    }

    /// 第七轮审计 06：写盘前再验一次代次——下载完成回调的守卫与真正落盘之间
    /// 仍有一道窗口（purge 可能正好夹在中间），这里是最后一道门；代次已变
    /// 即弃写，不重新创建刚删除的缓存目录。
    private func writeDisk(data: Data, key: String, ext: String, bucket: String, generation gen: UInt64) {
        guard isCurrentGeneration(gen, bucket: bucket) else { return }
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

    private func untrackTask(_ task: URLSessionDataTask, bucket: String) {
        stateLock.lock()
        inFlightTasks[bucket]?.removeAll { $0 === task }
        stateLock.unlock()
    }

    private func download(url: URL, key: String, ext: String, bucket: String, generation gen: UInt64, mimePrefix: String, completion: @escaping (Data?) -> Void) {
        var task: URLSessionDataTask?
        task = session.dataTask(with: url) { [weak self] data, response, _ in
            if let task = task { self?.untrackTask(task, bucket: bucket) }
            // 与图片加载器同口径：验 HTTP 2xx + MIME 前缀，不符按脏数据失败、
            // 不写缓存（错误页/HTML 误当视频或图片不再入库）。视频验 video/*、
            // 静态图验 image/*，见两处调用点。
            guard let self = self, self.isCurrentGeneration(gen, bucket: bucket),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let mime = http.mimeType, mime.hasPrefix(mimePrefix),
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
        inFlightTasks[bucket, default: []].append(task)
        stateLock.unlock()
        task.resume()
    }

    func load(staticKey: String, liveKey: String, contentMode: PHImageContentMode, completion: @escaping (PHLivePhoto?) -> Void) {
        // 桶在 load 起始固定：整条链路（磁盘读 / 网络写盘 / 内存键）都用它，
        // 切号夹在请求与回包之间时不再写进新号桶；桶变了即取消旧桶在途任务。
        let bucket = self.bucket()
        stateLock.lock()
        if activeBucket != bucket {
            // 切桶只失效旧桶：推进旧桶代次、取消旧桶在途任务；新桶代次不动，
            // 其旧任务早在离开该桶时已失效，切回不重复推进。
            let oldBucket = activeBucket
            let stale: [URLSessionDataTask]
            if let oldBucket = oldBucket {
                generations[oldBucket, default: 0] += 1
                stale = inFlightTasks[oldBucket] ?? []
                inFlightTasks[oldBucket] = nil
            } else {
                stale = []
            }
            activeBucket = bucket
            // 旧桶在途加载的等待方仍由各自链路的 finish 分发 nil（任务取消即
            // 回包）；注册表只清旧桶条目，不让新桶同 key 误接旧链（finish
            // 清表时凭对象身份比对，新链不受旧链终结牵连）。
            // 键含桶前缀（"桶|liveKey"），按旧桶前缀过滤，只清旧桶条目。
            if let oldBucket = oldBucket {
                inFlightLoads = inFlightLoads.filter { !($0.key as String).hasPrefix("\(oldBucket)|") }
            }
            stateLock.unlock()
            stale.forEach { $0.cancel() }
        } else {
            stateLock.unlock()
        }
        let gen = generation(for: bucket)
        if let cached = cache.object(forKey: memoryKey(bucket: bucket, liveKey: liveKey)) {
            completion(cached)
            return
        }
        guard let videoURL = BearyImageURLs.liveVideoURL(liveKey: liveKey),
              let stillURL = BearyImageURLs.imageURL(key: staticKey, thumb: false) else {
            completion(nil)
            return
        }
        // 同一资源对的在途加载共用：已在途时只挂等待，不再另发下载。
        let key = memoryKey(bucket: bucket, liveKey: liveKey)
        stateLock.lock()
        if let existing = inFlightLoads[key] {
            existing.completions.append(completion)
            stateLock.unlock()
            return
        }
        let box = InFlightLiveLoad()
        box.completions.append(completion)
        inFlightLoads[key] = box
        stateLock.unlock()
        // 终点唯一出口：清注册表、在主线程把同一份回包分发给所有等待方。
        let finish: (PHLivePhoto?) -> Void = { [weak self, box] photo in
            if let self = self {
                self.stateLock.lock()
                if self.inFlightLoads[key] === box { self.inFlightLoads.removeValue(forKey: key) }
                self.stateLock.unlock()
            }
            DispatchQueue.main.async { box.completions.forEach { $0(photo) } }
        }
        Self.diskQueue.async { [weak self] in
            guard let self = self, self.isCurrentGeneration(gen, bucket: bucket) else {
                // 过期任务也要结束回调（第七轮审计 07）：finish 在主线程回 nil，
                // 让视图清掉失败态；直接 return 会丢掉 completion，currentLiveKey
                // 永久残留，同一张图再 configure 会被跳过、实况永远不再出现。
                finish(nil)
                return
            }
            // 只补缺的那一份：视频只凭文件存在性判定（TTL 过期即清掉、按缺失
            // 算），不把整段 mov 读进内存；静图仍需读盘做占位图。
            let videoOnDisk = self.diskFileValid(key: liveKey, ext: "mov", bucket: bucket)
            let stillData = self.diskData(key: staticKey, ext: "jpg", bucket: bucket)
            if videoOnDisk, let stillData = stillData {
                // 磁盘双命中：视频只凭文件 URL 组装，不再读盘。
                self.buildLivePhoto(stillData: stillData, bucket: bucket, liveKey: liveKey, staticKey: staticKey, generation: gen, contentMode: contentMode, completion: finish)
                return
            }
            if videoOnDisk {
                // 视频已落盘，只下静图。
                self.download(url: stillURL, key: staticKey, ext: "jpg", bucket: bucket, generation: gen, mimePrefix: "image/") { [weak self] stillData in
                    guard let self = self, let stillData = stillData, self.isCurrentGeneration(gen, bucket: bucket) else {
                        finish(nil)
                        return
                    }
                    self.buildLivePhoto(stillData: stillData, bucket: bucket, liveKey: liveKey, staticKey: staticKey, generation: gen, contentMode: contentMode, completion: finish)
                }
                return
            }
            if let stillData = stillData {
                // 静图已落盘，只下视频。
                self.download(url: videoURL, key: liveKey, ext: "mov", bucket: bucket, generation: gen, mimePrefix: "video/") { [weak self] videoData in
                    guard let self = self, videoData != nil, self.isCurrentGeneration(gen, bucket: bucket) else {
                        finish(nil)
                        return
                    }
                    self.buildLivePhoto(stillData: stillData, bucket: bucket, liveKey: liveKey, staticKey: staticKey, generation: gen, contentMode: contentMode, completion: finish)
                }
                return
            }
            self.download(url: videoURL, key: liveKey, ext: "mov", bucket: bucket, generation: gen, mimePrefix: "video/") { [weak self] videoData in
                guard let self = self, videoData != nil, self.isCurrentGeneration(gen, bucket: bucket) else {
                    finish(nil)
                    return
                }
                self.download(url: stillURL, key: staticKey, ext: "jpg", bucket: bucket, generation: gen, mimePrefix: "image/") { stillData in
                    guard let stillData = stillData, self.isCurrentGeneration(gen, bucket: bucket) else {
                        finish(nil)
                        return
                    }
                    self.buildLivePhoto(stillData: stillData, bucket: bucket, liveKey: liveKey, staticKey: staticKey, generation: gen, contentMode: contentMode, completion: finish)
                }
            }
        }
    }

    /// 从视频文件读 Live Photo content identifier：QuickTime 元数据
    /// com.apple.quicktime.content-identifier（原始 MOV 由 PHAssetResource
    /// 导出，标识原样保留；个别写入器把它放在视频轨元数据里，一并扫）。
    /// 本地文件用 loadValuesAsynchronously + 信号量同步取，限时 5 秒；
    /// 超时/无标识返回 nil，调用方走旧路（request 仍会失败并记日志）。
    private static func livePhotoIdentifier(fromVideoFile videoFile: URL) -> String? {
        let asset = AVURLAsset(url: videoFile)
        let semaphore = DispatchSemaphore(value: 0)
        var identifier: String?
        asset.loadValuesAsynchronously(forKeys: ["metadata", "tracks"]) {
            defer { semaphore.signal() }
            var error: NSError?
            guard asset.statusOfValue(forKey: "metadata", error: &error) == .loaded else { return }
            let wanted = AVMetadataIdentifier.quickTimeMetadataContentIdentifier.rawValue
            let candidates: [[AVMetadataItem]] = [asset.metadata] + asset.tracks.map { $0.metadata }
            for items in candidates {
                for item in items {
                    let key = item.identifier?.rawValue ?? (item.key as? String) ?? ""
                    if key == wanted, let value = item.stringValue, !value.isEmpty {
                        identifier = value
                        return
                    }
                }
            }
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return identifier
    }

    /// 把 content identifier 写进 JPEG 元数据：EXIF MakerApple 字典 key "17"
    /// 即 Live Photo 配对标识的存放位置（与视频 MOV 里的
    /// com.apple.quicktime.content-identifier 同值）。源图无任何 EXIF 时
    /// 也能写（新建 MakerApple 字典）；失败返回 nil。
    private static func jpegDataByStampingIdentifier(_ stillData: Data, identifier: String) -> Data? {
        guard let source = CGImageSourceCreateWithData(stillData as CFData, nil),
              let uttype = CGImageSourceGetType(source) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, uttype, 1, nil) else { return nil }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        var makerApple = (properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]) ?? [:]
        makerApple["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary as String] = makerApple
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func buildLivePhoto(stillData: Data, bucket: String, liveKey: String, staticKey: String, generation gen: UInt64, contentMode: PHImageContentMode, completion: @escaping (PHLivePhoto?) -> Void) {
        guard let videoFile = self.fileURL(key: liveKey, ext: "mov", bucket: bucket),
              let stillFile = self.fileURL(key: staticKey, ext: "jpg", bucket: bucket),
              FileManager.default.fileExists(atPath: videoFile.path),
              FileManager.default.fileExists(atPath: stillFile.path) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard let placeholder = UIImage(data: stillData) else {
            // 静态数据解不出图：MIME 已验仍损坏的字节即无效缓存，删盘上下
            // 次重下；视频文件已验 MIME 且与本失败无关，保留。
            try? FileManager.default.removeItem(at: stillFile)
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // 标识对齐：服务端静帧是重编码后上传的 JPEG，元数据（含 content
        // identifier）已丢；视频是原始 MOV，仍带原始标识。PHLivePhoto.request
        // 要求两者标识一致，否则返回 nil。组装前把视频的标识写进静帧 JPEG，
        // 再调 request；已上传的老图也因此能播，不用重传。
        if let identifier = Self.livePhotoIdentifier(fromVideoFile: videoFile) {
            if let stamped = Self.jpegDataByStampingIdentifier(stillData, identifier: identifier) {
                // 覆盖写回同一缓存文件：本文件只供实况组装用（图片加载器另有
                // 自己的缓存），带标识的 JPEG 仍是同一张图的有效 JPEG，下次
                // 加载直接复用，不用重复盖章；重复盖章同值亦无害。
                try? stamped.write(to: stillFile, options: .atomic)
            } else {
                NSLog("[BearyLivePhoto] stamp identifier failed liveKey=%@ staticKey=%@", liveKey, staticKey)
            }
        } else {
            NSLog("[BearyLivePhoto] no content identifier in video liveKey=%@ staticKey=%@", liveKey, staticKey)
        }
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: placeholder.size.width * scale, height: placeholder.size.height * scale)
        _ = PHLivePhoto.request(
            withResourceFileURLs: [stillFile, videoFile],
            placeholderImage: placeholder,
            targetSize: targetSize,
            contentMode: contentMode
        ) { [weak self] photo, info in
            if let infoError = info[PHLivePhotoInfoErrorKey] as? Error {
                // 组装失败不再静默：此前 error 直接丢弃（photo, _ in），
                // 标识对不上时静默退化成静态帧，用户只看到“不播放”。
                NSLog("[BearyLivePhoto] PHLivePhoto.request failed liveKey=%@ staticKey=%@: %@", liveKey, staticKey, infoError.localizedDescription)
            }
            DispatchQueue.main.async {
                // 桶已切换的回包直接丢弃、不进新桶内存缓存（视图层 token 同样守门）。
                guard let photo = photo, let self = self, self.isCurrentGeneration(gen, bucket: bucket) else {
                    // 组装失败且静态帧已验有效、代次仍有效：无效方在视频侧，
                    // 删视频盘缓存以便下次重下；静态盘缓存保留，调用方仍可
                    // 用原静态帧降级展示（本加载器只叠加实况层，不动原图）。
                    if photo == nil, let self = self, self.isCurrentGeneration(gen, bucket: bucket) {
                        try? FileManager.default.removeItem(at: videoFile)
                    }
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
/// 角标与加载态：只要配了 liveKey 就亮左上“实况”角标（网页版同款：
/// 黑底 55%、白字 11pt bold、左上 6pt），加载中亮“实况”＋居中转圈；
/// 加载失败时角标改写“实况加载失败”，与就绪态区分开——用户能分清
/// “是实况但没加载出来”还是“根本不是实况”；失败时长按重试一次。
/// 读屏（第 25 轮 71、72）：角标是本视图唯一的无障碍元素，上面挂
/// “播放实况／重试实况”自定义操作，失败时标签也说明加载失败。
final class BearyLivePhotoView: UIView {
    private let liveView = PHLivePhotoView()
    private let photoContentMode: PHImageContentMode
    private var currentLiveKey: String?
    private var loadToken = 0
    /// 失败后长按重试要用的 key（configure 时记下，clear 时清掉）。
    private var pendingStaticKey: String?
    private var pendingLiveKey: String?
    private var isLoading = false
    /// 实况加载失败后为真：角标改写失败文案、读屏操作改成重试（第 25 轮 72）。
    private var loadFailed = false
    private let badgeView = UIView()
    private let badgeLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// 长按播完抬手时，调用方凭此压住紧随其后的那次点按（防长按变进灯箱）。
    var suppressTapUntil: Date?

    var hasLivePhoto: Bool {
        return liveView.livePhoto != nil
    }

    /// 已配实况 key（加载中/失败都为真）：角标可见时为真，长按可重试。
    var hasLiveKey: Bool {
        return pendingLiveKey != nil
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
        // “实况”角标（网页版 liveBadgeHtml 同款）：黑底 55%、白字 11pt bold、
        // pill 圆角、左上 6pt；只在配了 liveKey 时显现。
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.backgroundColor = UIColor(white: 0, alpha: 0.55)
        badgeView.clipsToBounds = true
        badgeView.isHidden = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.text = "实况"
        // 2026-11-08 实况角标单列 11 bold 语义档（Li 定，T3-D2）：尺寸不变，跟系统字号。
        badgeLabel.font = BearyDynamicType.liveBadgeFont()
        badgeLabel.adjustsFontForContentSizeCategory = true
        badgeLabel.textColor = .white
        badgeLabel.isAccessibilityElement = true
        badgeLabel.accessibilityLabel = "实况照片"
        badgeView.addSubview(badgeLabel)
        addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badgeView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -3),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -8),
        ])
        // 加载圈：居中、白、加载中才转；静态帧仍在下层可见，转圈只表示
        // “实况视频还在下”，不是整图加载。
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 读屏操作与失败说明（第 25 轮 71、72）：角标是本视图唯一的无障碍
    /// 元素，在它上面挂自定义操作——就绪时“播放实况”，失败时“重试实况”；
    /// 失败时角标文字与读屏标签都说明加载失败，加载中不挂操作。
    private func updateAccessibility() {
        if loadFailed {
            badgeLabel.text = "实况加载失败"
            badgeLabel.accessibilityLabel = "实况照片，加载失败"
            badgeLabel.accessibilityHint = "实况加载失败，长按重试"
            badgeLabel.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "重试实况") { [weak self] _ in
                    return self?.startPlayback() ?? false
                }
            ]
        } else if liveView.livePhoto != nil {
            badgeLabel.text = "实况"
            badgeLabel.accessibilityLabel = "实况照片"
            badgeLabel.accessibilityHint = nil
            badgeLabel.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "播放实况") { [weak self] _ in
                    return self?.startPlayback() ?? false
                }
            ]
        } else {
            badgeLabel.text = "实况"
            badgeLabel.accessibilityLabel = "实况照片"
            badgeLabel.accessibilityHint = isLoading ? "正在加载实况" : nil
            badgeLabel.accessibilityCustomActions = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        badgeView.layer.cornerRadius = badgeView.bounds.height / 2
    }

    /// staticKey/liveKey 任一为空即按无实况处理（旧静态图、非实况图走这里）。
    /// 同一 liveKey 重复调用不重复加载；换 key 时旧加载回包凭 token 丢弃。
    /// 有 liveKey 即亮角标＋转圈（加载中/失败都亮角标，见类注释）。
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
        pendingStaticKey = staticKey
        pendingLiveKey = liveKey
        badgeView.isHidden = false
        isLoading = true
        loadFailed = false
        spinner.startAnimating()
        isHidden = false
        updateAccessibility()
        loadToken += 1
        let token = loadToken
        BearyLivePhotoLoader.shared.load(staticKey: staticKey, liveKey: liveKey, contentMode: photoContentMode) { [weak self] photo in
            guard let self = self, token == self.loadToken, self.currentLiveKey == liveKey else { return }
            self.isLoading = false
            self.spinner.stopAnimating()
            if let photo = photo {
                self.liveView.livePhoto = photo
                self.loadFailed = false
            } else {
                // 失败仍亮角标（不静默退化成纯静态），但角标改写失败文案、
                // 读屏操作改成重试，与就绪态区分开（第 25 轮 72）；
                // currentLiveKey 清掉，下次 configure 或长按重试可重新加载；
                // 加载中的同 key 调用仍由 token＋currentLiveKey 守门，不会重复拉。
                self.currentLiveKey = nil
                self.loadFailed = true
            }
            self.updateAccessibility()
        }
    }

    func clear() {
        loadToken += 1
        currentLiveKey = nil
        pendingStaticKey = nil
        pendingLiveKey = nil
        isLoading = false
        loadFailed = false
        spinner.stopAnimating()
        badgeView.isHidden = true
        liveView.livePhoto = nil
        isHidden = true
        suppressTapUntil = nil
        updateAccessibility()
    }

    /// 长按播实况：已就绪即播；加载中已有转圈可见（不是空操作）；加载
    /// 失败时长按重试一次。返回 true 表示播了或触发了重试，false 表示
    /// 正在加载中（调用方不立抬手压制窗，点按照常）。
    @discardableResult
    func startPlayback() -> Bool {
        if liveView.livePhoto != nil {
            liveView.startPlayback(with: .full)
            return true
        }
        if isLoading {
            return false
        }
        guard let staticKey = pendingStaticKey, let liveKey = pendingLiveKey else {
            return false
        }
        configure(staticKey: staticKey, liveKey: liveKey)
        return true
    }
}
