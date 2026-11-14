import UIKit
import ImageIO

// ===== 用户自传 GIF：内联 GIF 记号 [gif:<rand>] =====
// 正文/标题里的 GIF 只存记号（rand = 服务端 image key 里的随机部分，
// 如 `123/1794482000000_ab12cd34.gif` → `ab12cd34`），完整 key 随日记
// images 数组走（发布/更新/GC 共用照片口径）；旧客户端看不到图时只显示
// 记号原文，不崩。卡片/详情/时间线用覆盖层播动画（UILabel 不能直接播附件
// 动画）；编辑器里只显首帧静态图（与心情附件同款静态口径，动画在卡片/
// 详情/时间线里播）。减动效下一律首帧静态图；覆盖层监听减动效变化，
// 已显示的 GIF 在开关打开后立即切静帧、关闭后恢复动画（第 25 轮 7）。
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
    /// 动画帧槽上限：变速帧按停留时间在动画里占多槽（同一 UIImage 复用，
    /// 只多存数组引用、不复制像素），总槽数封顶，避免长停留帧把槽数撑爆。
    static let maxAnimatedSlots = 200

    /// 解码结果：动画图 + 原始循环次数 + 单次播放总时长。
    /// loopCount：nil = 资源未声明循环块，沿用旧口径无限循环；
    /// 0 = 资源声明无限循环；>0 = 总共播放这么多次。
    struct DecodedGIF {
        let image: UIImage
        let loopCount: Int?
        let duration: TimeInterval
    }

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
    /// 兼容旧调用：只取动画图时用它；要循环次数与单次时长时用 decodedImage。
    static func animatedImage(_ data: Data) -> UIImage? {
        return decodedImage(data)?.image
    }

    /// 解帧成动画（含循环次数与单次时长）：
    /// - 全程抽帧（第 25 轮 64）：帧数超上限时按总帧数均匀取 maxDecodedFrames
    ///   帧覆盖全程，不再只取前 40 帧；解出的像素量与旧口径相同，不加内存。
    /// - 帧延时（第 25 轮 65）：UIImage.animatedImage 只能均分时长，这里按
    ///   各帧实际停留时间占槽——一帧在动画数组里重复出现多次（同一 UIImage
    ///   复用，不复制像素），停留久的帧占槽多，总时长仍为各帧延时之和；
    ///   被抽掉的帧的延时并进代表它的采样帧。
    /// - 循环次数（第 25 轮 66）：读 GIF 循环块（NETSCAPE2.0 loop count）；
    ///   未声明或声明 0 均为无限循环，声明 N>0 为总共播 N 次。
    /// 减动效时只回首帧（loopCount 为 nil、duration 为 0，调用方按静帧处理）。
    static func decodedImage(_ data: Data) -> DecodedGIF? {
        if UIAccessibility.isReduceMotionEnabled {
            guard let first = firstFrameImage(data) else { return nil }
            return DecodedGIF(image: first, loopCount: nil, duration: 0)
        }
        guard isGIFData(data), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // 全程抽帧：≤ 上限全解；超上限按总帧数均匀取帧。
        var indices: [Int] = []
        if count <= maxDecodedFrames {
            indices = Array(0..<count)
        } else {
            for i in 0..<maxDecodedFrames { indices.append(i * count / maxDecodedFrames) }
        }
        // 各采样帧的有效延时 = 它所代表的那段原帧的延时之和。
        var frames: [(image: UIImage, delay: TimeInterval)] = []
        for (j, index) in indices.enumerated() {
            let end = j + 1 < indices.count ? indices[j + 1] : count
            var delay: TimeInterval = 0
            for k in index..<end { delay += delayForFrame(source: source, index: k) }
            guard let cg = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let raw = UIImage(cgImage: cg)
            frames.append((downsampled(raw, maxSide: maxDecodedSide) ?? raw, delay))
        }
        guard !frames.isEmpty else { return nil }
        let totalDuration = frames.reduce(0) { $0 + $1.delay }
        if frames.count == 1 { return DecodedGIF(image: frames[0].image, loopCount: loopCount(of: source), duration: max(totalDuration, 0.1)) }
        // 按停留时间占槽：量化单位取最小有效延时，总槽数超上限时放大单位重算。
        var unit = frames.map { $0.delay }.min() ?? 0.1
        if unit < 0.02 { unit = 0.02 }
        var slots = frames.map { max(1, Int(round($0.delay / unit))) }
        if slots.reduce(0, +) > maxAnimatedSlots {
            unit = max(totalDuration / TimeInterval(maxAnimatedSlots), 0.02)
            slots = frames.map { max(1, Int(round($0.delay / unit))) }
        }
        var images: [UIImage] = []
        for (j, frame) in frames.enumerated() {
            for _ in 0..<slots[j] { images.append(frame.image) }
        }
        guard !images.isEmpty else { return nil }
        let animated = UIImage.animatedImage(with: images, duration: max(totalDuration, 0.1))
        return DecodedGIF(image: animated, loopCount: loopCount(of: source), duration: max(totalDuration, 0.1))
    }

    /// GIF 循环块读数：无循环块返回 nil（调用方按无限循环处理，沿用旧口径）。
    private static func loopCount(of source: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
              let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any],
              let loop = gifProps[kCGImagePropertyGIFLoopCount] as? NSNumber else { return nil }
        return loop.intValue
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
/// 减动效监听（第 25 轮 7）：init 即注册减动效变化通知，开关打开后已显示
/// 的 GIF 立即切静帧、关闭后恢复动画；只改 GIF 路径，不动 Lottie。
/// 失败重试（第 25 轮 68）：加载失败的 key 记入 failedKeys；下次 update
/// （即使布局签名不变）、回前台（网络常在此时恢复）与 retryFailedGIFs()
/// 都会重载；失败时不写缓存，加载器下次仍会重新请求网络。
final class BearyInlineGIFOverlay {

    private weak var label: UILabel?
    private var gifKeys: [String] = []
    private var views: [String: UIImageView] = [:]
    private var animatedImages: [String: UIImage] = [:]
    private var firstFrames: [String: UIImage] = [:]
    /// 有限循环 GIF 的播放信息（循环次数 + 单次时长），用于播完停在末帧。
    private var loopInfo: [String: (loopCount: Int?, duration: TimeInterval)] = [:]
    /// 有限循环 GIF 的停播任务（播完切末帧），换图/隐藏/清掉时取消。
    private var loopStopWorkItems: [String: DispatchWorkItem] = [:]
    private var loadingKeys: Set<String> = []
    private var failedKeys: Set<String> = []
    private var lastSignature: String = ""
    private var lastWidth: CGFloat = 0
    private var visible: Bool = true
    /// 长按 GIF 时的回调（randKey → 调用方弹“添加表情”）。
    var onLongPressGIF: ((String) -> Void)?

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(foregroundEntered), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit {
        for item in loopStopWorkItems.values { item.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    /// 减动效变化：打开后所有已显示 GIF 立即切静帧并停掉有限循环的停播
    /// 任务；关闭后恢复动画（有限循环的重新从头计时）。
    @objc private func reduceMotionChanged() {
        refreshViewImages()
    }

    /// 回前台：网络常在此时恢复，重载之前失败的 GIF。
    @objc private func foregroundEntered() {
        retryFailedGIFs()
    }

    /// 当前应显示的图：减动效或不可见时首帧，否则动画（未解出时先用首帧）。
    private func image(for randKey: String) -> UIImage? {
        if UIAccessibility.isReduceMotionEnabled || !visible {
            return firstFrames[randKey]
        }
        return animatedImages[randKey] ?? firstFrames[randKey]
    }

    /// 按当前减动效/可见状态重刷全部覆盖视图的图；有限循环 GIF 在此
    /// （重）新计时，播完停在末帧。
    private func refreshViewImages() {
        for (id, view) in views {
            let rand = id.components(separatedBy: "#").first ?? ""
            view.image = image(for: rand)
        }
        rearmLoopStops()
    }

    /// 有限循环 GIF：播完（单次时长 × 次数）后停在末帧；无限循环/减动效/
    /// 不可见时不计时。旧任务先取消，避免复用后旧计时把新图切掉。
    private func rearmLoopStops() {
        for item in loopStopWorkItems.values { item.cancel() }
        loopStopWorkItems.removeAll()
        guard visible, !UIAccessibility.isReduceMotionEnabled else { return }
        for (rand, info) in loopInfo {
            guard let count = info.loopCount, count > 0, info.duration > 0,
                  animatedImages[rand] != nil else { continue }
            let delay = info.duration * TimeInterval(count)
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.visible, !UIAccessibility.isReduceMotionEnabled else { return }
                let last = self.animatedImages[rand]?.images?.last ?? self.firstFrames[rand]
                for (id, view) in self.views {
                    let r = id.components(separatedBy: "#").first ?? ""
                    guard r == rand else { continue }
                    view.image = last
                }
            }
            loopStopWorkItems[rand] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

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
        for item in loopStopWorkItems.values { item.cancel() }
        loopStopWorkItems.removeAll()
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
        lastSignature = ""
        lastWidth = 0
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        refreshViewImages()
    }

    /// 手动重试之前加载失败的 GIF（调用方可挂到失败态入口；无失败 key 时空转）。
    func retryFailedGIFs() {
        for rand in failedKeys { loadGIF(randKey: rand) }
    }

    /// 宽或文本变化时重算矩形（label 布局落位后调；无 GIF 附件时直接返回）。
    func update() {
        guard let label = label, let attributed = label.attributedText, attributed.length > 0,
              label.bounds.width > 0 else {
            clear()
            return
        }
        let signature = layoutSignature(label: label, attributed: attributed)
        if signature == lastSignature {
            // 签名不变时不再重算矩形，但之前失败的 GIF 要重载（第 25 轮 68）：
            // 网络恢复后同一页不靠布局变化也能重新拿到图。
            retryFailedGIFs()
            return
        }
        lastSignature = signature
        lastWidth = label.bounds.width
        let rects = attachmentRects(label: label, attributed: attributed)
        var seen: Set<String> = []
        for (id, rand, rect) in rects {
            seen.insert(id)
            if let view = views[id] {
                if view.frame != rect { view.frame = rect }
                continue
            }
            let view = UIImageView()
            view.contentMode = .scaleAspectFit
            view.clipsToBounds = true
            view.isUserInteractionEnabled = true
            view.frame = rect
            view.image = image(for: rand)
            let press = UILongPressGestureRecognizer(target: self, action: #selector(overlayLongPressed(_:)))
            press.minimumPressDuration = 0.5
            view.addGestureRecognizer(press)
            label.addSubview(view)
            views[id] = view
            loadGIF(randKey: rand)
        }
        for (id, view) in views where seen.contains(id) == false {
            view.removeFromSuperview()
            views.removeValue(forKey: id)
        }
    }

    /// 布局缓存签名（第 25 轮 67）：除旧口径的文本 hash、行数、宽度外，
    /// 再含 label 字体、全文段落行高参数与各 GIF 附件尺寸；任一变化都
    /// 作废缓存、重算矩形。
    private func layoutSignature(label: UILabel, attributed: NSAttributedString) -> String {
        var parts: [String] = []
        parts.append("\(attributed.string.hashValue)")
        parts.append("\(label.numberOfLines)")
        parts.append("\(label.bounds.width)")
        parts.append("\(label.font.fontName)-\(label.font.pointSize)")
        var paraParts: [String] = []
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let p = "\(style.lineSpacing)/\(style.minimumLineHeight)/\(style.maximumLineHeight)/\(style.lineHeightMultiple)"
            if !paraParts.contains(p) { paraParts.append(p) }
        }
        parts.append(paraParts.joined(separator: ","))
        var attachParts: [String] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let s = "\(attachment.bounds.size.width)x\(attachment.bounds.size.height)"
            if !attachParts.contains(s) { attachParts.append(s) }
        }
        parts.append(attachParts.joined(separator: ","))
        return parts.joined(separator: "#")
    }

    @objc private func overlayLongPressed(_ sender: UILongPressGestureRecognizer) {
        guard sender.state == .began, let view = sender.view else { return }
        for (id, candidate) in views where candidate === view {
            let rand = id.components(separatedBy: "#").first ?? ""
            if !rand.isEmpty { onLongPressGIF?(rand) }
            return
        }
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
            var decoded: BearyGIF.DecodedGIF?
            var first: UIImage?
            var failed = false
            if case .success(let data) = result {
                first = BearyGIF.firstFrameImage(data)
                decoded = BearyGIF.decodedImage(data)
            } else {
                failed = true
            }
            DispatchQueue.main.async {
                self.loadingKeys.remove(randKey)
                if failed {
                    // 加载失败记入 failedKeys：覆盖视图仍在（占位），下次 update、
                    // 回前台或调用方调 retryFailedGIFs() 时重载（第 25 轮 68）。
                    self.failedKeys.insert(randKey)
                    return
                }
                self.failedKeys.remove(randKey)
                if let first = first { self.firstFrames[randKey] = first }
                if let decoded = decoded {
                    self.animatedImages[randKey] = decoded.image
                    self.loopInfo[randKey] = (decoded.loopCount, decoded.duration)
                }
                for (id, view) in self.views {
                    let rand = id.components(separatedBy: "#").first ?? ""
                    guard rand == randKey else { continue }
                    view.image = self.image(for: rand)
                }
                self.rearmLoopStops()
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
