import UIKit
import ImageIO

// ===== 用户自传 GIF：内联 GIF 记号 [gif:<rand>] =====
// 正文/标题里的 GIF 只存记号（rand = 服务端 image key 里的随机部分，
// 如 `123/1794482000000_ab12cd34.gif` → `ab12cd34`），完整 key 随日记
// images 数组走（发布/更新/GC 共用照片口径）；旧客户端看不到图时只显示
// 记号原文，不崩。卡片/详情/时间线用覆盖层播动画（UILabel 不能直接播附件
// 动画）；编辑器里只显首帧静态图（与心情附件同款静态口径，动画在卡片/
// 详情/时间线里播）。减动效下一律首帧静态图。
// 服务端口径（见 ~/workspace/beary-gif-upload-server.diff）：GIF 解码后
// 1MB 上限（照片仍 5MB）、单边 ≤1000px、帧数 ≤200；取图按 key 鉴权，
// 引用日记作者本人与本人库成员放行；库只引用 key、不复制文件。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyGIF {

    /// GIF 解码后上限 1MB（服务端同值；超了服务端 413 'gif too large'）。
    static let maxBytes = 1 * 1024 * 1024
    /// 单边 ≤1000px（服务端同值）。
    static let maxSide = 1000
    /// 帧数 ≤200（服务端同值，走 image descriptor 计数）。
    static let maxFrames = 200
    /// 解帧上限：帧压到 200px、最多 40 帧。
    static let maxDecodedFrames = 40
    static let maxDecodedSide: CGFloat = 200

    static func isGIFData(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        return data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38
            && (data[4] == 0x37 || data[4] == 0x39) && data[5] == 0x61
    }

    /// GIF 头信息：逻辑屏宽高 + 帧数（沿块结构走，数 0x2C 的个数，不在
    /// 压缩数据里数裸字节，否则误计）。与服务端 gifInfo 同款走法；
    /// 结构非法返回 nil。
    static func info(_ data: Data) -> (w: Int, h: Int, frames: Int)? {
        guard isGIFData(data), data.count >= 13 else { return nil }
        let w = Int(data[6]) | (Int(data[7]) << 8)
        let h = Int(data[8]) | (Int(data[9]) << 8)
        let packed = data[10]
        var off = 13
        if packed & 0x80 != 0 { off += 3 * (1 << ((Int(packed) & 0x07) + 1)) }
        var frames = 0
        while off < data.count {
            let b = data[off]
            if b == 0x3B { break }
            if b == 0x2C {
                frames += 1
                guard off + 10 <= data.count else { return nil }
                let ipacked = data[off + 9]
                off += 10
                if ipacked & 0x80 != 0 { off += 3 * (1 << ((Int(ipacked) & 0x07) + 1)) }
                off += 1
                while off < data.count {
                    let n = Int(data[off])
                    off += 1 + n
                    if n == 0 { break }
                }
            } else if b == 0x21 {
                off += 2
                while off < data.count {
                    let n = Int(data[off])
                    off += 1 + n
                    if n == 0 { break }
                }
            } else {
                return nil
            }
        }
        return (w, h, frames)
    }

    /// 首帧静态图（减动效 / 编辑器 / 占位都用它）。
    static func firstFrameImage(_ data: Data) -> UIImage? {
        guard isGIFData(data), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 解帧成 animated UIImage：帧压到 200px、最多 40 帧；延时取
    /// UnclampedDelayTime → DelayTime，<0.02 按 0.1 计；减动效只回首帧。
    static func animatedImage(_ data: Data) -> UIImage? {
        if UIAccessibility.isReduceMotionEnabled { return firstFrameImage(data) }
        guard isGIFData(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let frames = min(count, maxDecodedFrames)
        var images: [UIImage] = []
        var totalDuration: TimeInterval = 0
        for i in 0..<frames {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let raw = UIImage(cgImage: cg)
            images.append(downsampled(raw, maxSide: maxDecodedSide) ?? raw)
            totalDuration += delayForFrame(source: source, index: i)
        }
        guard !images.isEmpty else { return nil }
        if images.count == 1 { return images[0] }
        return UIImage.animatedImage(with: images, duration: max(totalDuration, 0.1))
    }

    private static func delayForFrame(source: CGImageSource, index: Int) -> TimeInterval {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gifProps[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }

    /// 按像素缩到长边 maxSide（小图原样返回；format.scale = 1，不吃屏 scale）。
    private static func downsampled(_ image: UIImage, maxSide: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let longest = max(cg.width, cg.height)
        guard longest > 0, CGFloat(longest) > maxSide else { return image }
        let ratio = maxSide / CGFloat(longest)
        let target = CGSize(width: max(1, round(CGFloat(cg.width) * ratio)),
                            height: max(1, round(CGFloat(cg.height) * ratio)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// 完整 key → rand 部分（`123/1794482000000_ab12cd34.gif` → `ab12cd34`）。
    static func randKey(from fullKey: String) -> String? {
        let last = fullKey.split(separator: "/").last.map(String.init) ?? fullKey
        guard let underscore = last.lastIndex(of: "_") else { return nil }
        let rand = String(last[last.index(after: underscore)...])
        guard rand.hasSuffix(".gif") else { return nil }
        let bare = String(rand.dropLast(4))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard !bare.isEmpty, bare.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return bare
    }

    /// rand → 完整 key（在 entry.images 里按 rand 后缀找回）。
    static func fullKey(for randKey: String, in keys: [String]) -> String? {
        return keys.first { BearyGIF.randKey(from: $0) == randKey }
    }
}

// MARK: - UILabel 上的 GIF 覆盖层（卡片 / 详情 / 时间线）

/// UILabel 不能直接播附件动画：附件本身只画占位（surface2 圆角矩形），
/// 本管理器按 NSLayoutManager 算出每个 GIF 附件的矩形，在 label 上贴
/// UIImageView 播 animated UIImage。只对实际排版出的字形贴图（折叠后
/// 6 行外的、标题截断掉的都不贴）；宽变时刷新；复用时清理。
/// 可见性：setVisible(false) 时换首帧静态图（滚动出屏、切 tab、复用前），
/// setVisible(true) 时换回动画；减动效下 animatedImage 本身即首帧。
final class BearyInlineGIFOverlay {

    private weak var label: UILabel?
    private var gifKeys: [String] = []
    private var views: [String: UIImageView] = [:]
    private var animatedImages: [String: UIImage] = [:]
    private var firstFrames: [String: UIImage] = [:]
    private var loadingKeys: Set<String> = []
    private var lastSignature: String = ""
    private var lastWidth: CGFloat = 0
    private var visible: Bool = true
    /// 长按 GIF 时的回调（randKey → 调用方弹“添加表情”）；读屏
    /// “添加到我的表情”自定义操作（第 25 轮 70 项）走同一回调。
    var onLongPressGIF: ((String) -> Void)?

    /// 绑 label + 本篇 images 里的 key + 长按回调；调后即按当前 attributedText 贴图。
    /// 宽变或文本重建后重复调（同一 label + 同一批 key 时不重置签名，
    /// update 内部按文本/宽度签名短路；换篇/换 key 时重置，强制重算矩形）。
    func attach(to label: UILabel, gifKeys: [String], onLongPressGIF: ((String) -> Void)? = nil) {
        self.onLongPressGIF = onLongPressGIF
        // UILabel 默认不收触摸：覆盖层上的长按手势须先开交互（label 本身无
        // 手势、不拦点按与滚动，卡片行选、详情滚动都不受影响）。
        label.isUserInteractionEnabled = true
        if self.label !== label || self.gifKeys != gifKeys {
            self.label = label
            self.gifKeys = gifKeys
            lastSignature = ""
            lastWidth = 0
        }
        update()
    }

    /// 复用 / 内容清空时调：摘掉全部覆盖视图（已加载的图仍缓存在本管理器内，
    /// 同一管理器重绑同一篇时不再重下）。
    func clear() {
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
        lastSignature = ""
        lastWidth = 0
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        for (id, view) in views {
            let rand = id.components(separatedBy: "#").first ?? ""
            view.image = visible ? (animatedImages[rand] ?? firstFrames[rand]) : firstFrames[rand]
        }
    }

    /// 宽或文本变化时重算矩形（label 布局落位后调；无 GIF 附件时直接返回）。
    func update() {
        guard let label = label, let attributed = label.attributedText, attributed.length > 0,
              label.bounds.width > 0 else {
            clear()
            return
        }
        let signature = "\(attributed.string.hashValue)#\(label.numberOfLines)#\(label.bounds.width)"
        if signature == lastSignature { return }
        lastSignature = signature
        lastWidth = label.bounds.width
        let rects = attachmentRects(label: label, attributed: attributed)
        var seen: Set<String> = []
        for (offset, item) in rects.enumerated() {
            let (id, rand, rect) = item
            seen.insert(id)
            if let view = views[id] {
                if view.frame != rect { view.frame = rect }
                applyGIFAccessibility(to: view, rand: rand, index: offset + 1)
                continue
            }
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.clipsToBounds = true
            view.isUserInteractionEnabled = true
            view.frame = rect
            view.image = visible ? (animatedImages[rand] ?? firstFrames[rand]) : firstFrames[rand]
            let press = UILongPressGestureRecognizer(target: self, action: #selector(overlayLongPressed(_:)))
            press.minimumPressDuration = 0.5
            view.addGestureRecognizer(press)
            applyGIFAccessibility(to: view, rand: rand, index: offset + 1)
            label.addSubview(view)
            views[id] = view
            loadGIF(randKey: rand)
        }
        for (id, view) in views where seen.contains(id) == false {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
    }

    @objc private func overlayLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began, let view = sender.view else { return }
        for (id, candidate) in views where candidate === view {
            let rand = id.components(separatedBy: "#").first ?? ""
            if !rand.isEmpty { onLongPressGIF?(rand) }
            return
        }
    }

    /// 第 25 轮 70 项：正文 GIF 附件的读屏入口——按正文顺序编号区分，
    /// “添加到我的表情”自定义操作与长按同一路（弹确认底 sheet 再入库）。
    private func applyGIFAccessibility(to view: UIImageView, rand: String, index: Int) {
        view.isAccessibilityElement = true
        view.accessibilityLabel = "GIF，第 \(index) 个"
        view.accessibilityTraits = [.image]
        view.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "添加到我的表情") { [weak self] _ in
            guard let self = self, !rand.isEmpty else { return false }
            self.onLongPressGIF?(rand)
            return true
        }]
    }

    /// 用 NSLayoutManager 按 label 实际排版算 GIF 附件矩形（label 坐标系）；
    /// id = rand + 字符位置（同一 GIF 出现两次各贴一张）。
    private func attachmentRects(label: UILabel, attributed: NSAttributedString) -> [(id: String, rand: String, rect: CGRect)] {
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = label.numberOfLines
        container.lineBreakMode = label.lineBreakMode
        layout.addTextContainer(container)
        let textRect = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
        var out: [(String, String, CGRect)] = []
        attributed.enumerateAttribute(BearyText.inlineGifKeyAttribute, in: NSRange(location: 0, length: attributed.length), options: []) { value, range, _ in
            guard let rand = value as? String, !rand.isEmpty else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return }
            var rect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            rect = rect.offsetBy(dx: textRect.origin.x, dy: textRect.origin.y)
            guard rect.width > 0, rect.height > 0, textRect.intersects(rect) else { return }
            out.append(("\(rand)#\(range.location)", rand, rect))
        }
        return out
    }

    private func loadGIF(randKey: String) {
        guard loadingKeys.contains(randKey) == false, animatedImages[randKey] == nil else { return }
        guard let fullKey = BearyGIF.fullKey(for: randKey, in: gifKeys),
              let url = BearyImageURLs.imageURL(key: fullKey, thumb: false) else { return }
        loadingKeys.insert(randKey)
        BearyImageLoader.shared.loadImageData(url: url) { [weak self] result in
            guard let self = self else { return }
            // 解帧放后台线程（最多 40 帧），解完切主线程贴图。
            var animated: UIImage?
            var first: UIImage?
            if case .success(let data) = result {
                first = BearyGIF.firstFrameImage(data)
                animated = BearyGIF.animatedImage(data)
            }
            DispatchQueue.main.async {
                self.loadingKeys.remove(randKey)
                if let first = first { self.firstFrames[randKey] = first }
                if let animated = animated { self.animatedImages[randKey] = animated }
                for (id, view) in self.views {
                    let rand = id.components(separatedBy: "#").first ?? ""
                    guard rand == randKey else { continue }
                    view.image = self.visible ? (animated ?? first) : first
                }
            }
        }
    }
}

// MARK: - 长按 GIF 加进我的表情库（详情 / 卡片 / 时间线共用）

/// 就近找 presenter 弹确认底 sheet（标题留空、与详情 ⋯ 菜单同款），
/// 点“添加表情”即调库接口；结果 toast 复用现有失败文案口径。
enum BearyGIFAddPresenter {

    static func presentAddGIF(from view: UIView, fullKey: String) {
        guard let vc = nearestViewController(from: view) else { return }
        BearyConfirmSheet.show(from: vc, title: "", message: nil, actions: [
            BearyConfirmSheet.Action(title: "添加表情", style: .default, handler: { [weak vc] in
                guard let vc = vc else { return }
                BearyGIFLibrary.add(key: fullKey) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .added: BearyToast.show(in: vc.view, message: "已添加到我的 GIF")
                        case .alreadyAdded: BearyToast.show(in: vc.view, message: "已添加过")
                        case .full: BearyToast.show(in: vc.view, message: "表情库满了，先删掉一些再添加")
                        case .notViewable: BearyToast.show(in: vc.view, message: "这个 GIF 已经加不了了")
                        case .failed: BearyToast.show(in: vc.view, message: "添加失败，请重试")
                        }
                    }
                }
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel),
        ])
    }

    private static func nearestViewController(from view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}
