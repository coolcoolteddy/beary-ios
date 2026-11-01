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

    private init() {
        let config = URLSessionConfiguration.default
        self.session = URLSession(configuration: config, delegate: BearyImageRedirectGuard.shared, delegateQueue: nil)
    }

    private func bucket() -> String {
        if let id = BearyImageLoader.shared.currentAccountId {
            return String(id)
        }
        return "guest"
    }

    private func fileURL(key: String, ext: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + "." + ext
        let dir = caches.appendingPathComponent("BearyLiveCache").appendingPathComponent(bucket(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent(name)
    }

    private func download(url: URL, key: String, ext: String, completion: @escaping (Data?) -> Void) {
        guard let file = fileURL(key: key, ext: ext) else {
            completion(nil)
            return
        }
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            completion(data)
            return
        }
        let task = session.dataTask(with: url) { data, response, _ in
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data = data, !data.isEmpty else {
                completion(nil)
                return
            }
            try? data.write(to: file, options: .atomic)
            completion(data)
        }
        task.resume()
    }

    func load(staticKey: String, liveKey: String, contentMode: PHImageContentMode, completion: @escaping (PHLivePhoto?) -> Void) {
        if let cached = cache.object(forKey: liveKey as NSString) {
            completion(cached)
            return
        }
        guard let videoURL = BearyImageURLs.liveVideoURL(liveKey: liveKey),
              let stillURL = BearyImageURLs.imageURL(key: staticKey, thumb: false) else {
            completion(nil)
            return
        }
        download(url: videoURL, key: liveKey, ext: "mov") { [weak self] videoData in
            guard let self = self, videoData != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.download(url: stillURL, key: staticKey, ext: "jpg") { stillData in
                guard let stillData = stillData,
                      let videoFile = self.fileURL(key: liveKey, ext: "mov"),
                      let stillFile = self.fileURL(key: staticKey, ext: "jpg"),
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
                        if let photo = photo {
                            self?.cache.setObject(photo, forKey: liveKey as NSString)
                        }
                        completion(photo)
                    }
                }
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
