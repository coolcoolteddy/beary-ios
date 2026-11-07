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

    private func buildLivePhoto(stillData: Data, bucket: String, liveKey: String, staticKey: String, generation gen: Int, contentMode: PHImageContentMode, completion: @escaping (PHLivePhoto?) -> Void) {
        guard let videoFile = self.fileURL(key: liveKey, ext: "mov", bucket: bucket),
              let stillFile = self.fileURL(key: staticKey, ext: "jpg", bucket: bucket),
              FileManager.default.fileExists(atPath: videoFile.path),
              FileManager.default.fileExists(atPath: stillFile.path),
              let placeholder = UIImage(data: stillData) else {
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
/// 角标与加载态：只要配了 liveKey 就亮左上“实况”角标（网页版同款：
/// 黑底 55%、白字 11pt bold、左上 6pt），加载中/加载失败都亮——用户
/// 能分清“是实况但没加载出来”还是“根本不是实况”；加载中另有居中转圈，
/// 长按不是空操作（加载中转圈可见，失败时长按重试一次）。
final class BearyLivePhotoView: UIView {
    private let liveView = PHLivePhotoView()
    private let photoContentMode: PHImageContentMode
    private var currentLiveKey: String?
    private var loadToken = 0
    /// 失败后长按重试要用的 key（configure 时记下，clear 时清掉）。
    private var pendingStaticKey: String?
    private var pendingLiveKey: String?
    private var isLoading = false
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
        badgeLabel.font = UIFont.systemFont(ofSize: 11, weight: .bold)
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
        spinner.startAnimating()
        isHidden = false
        loadToken += 1
        let token = loadToken
        BearyLivePhotoLoader.shared.load(staticKey: staticKey, liveKey: liveKey, contentMode: photoContentMode) { [weak self] photo in
            guard let self = self, token == self.loadToken, self.currentLiveKey == liveKey else { return }
            self.isLoading = false
            self.spinner.stopAnimating()
            if let photo = photo {
                self.liveView.livePhoto = photo
            } else {
                // 失败仍亮角标（不静默退化成纯静态），currentLiveKey 清掉，
                // 下次 configure 或长按重试可重新加载；加载中的同 key 调用
                // 仍由 token＋currentLiveKey 守门，不会重复拉。
                self.currentLiveKey = nil
            }
        }
    }

    func clear() {
        loadToken += 1
        currentLiveKey = nil
        pendingStaticKey = nil
        pendingLiveKey = nil
        isLoading = false
        spinner.stopAnimating()
        badgeView.isHidden = true
        liveView.livePhoto = nil
        isHidden = true
        suppressTapUntil = nil
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
