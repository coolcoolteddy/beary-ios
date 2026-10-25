import UIKit
import ObjectiveC

// ===== 原生页共享契约（第二阶段第一项）=====
// 三个原生页（列表 / 详情 / 编辑器）共用：动态色、图片地址与加载、时间文案、
// 心情与天气名字、写接口响应模型、BearyAPI 扩展、图片压缩。
// 本地草稿 v2（文件原子写 + 图片落盘）见 BearyDraftFiles.swift。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 动态色（与 SceneDelegate 原生栏、网页三色制同值）

enum BearyColors {
    static var ink: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1) : .black } }
    static var gray: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.66, alpha: 1) : UIColor(white: 0.45, alpha: 1) } }
    static var orange: UIColor { UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1) }
    /// 语义红：网页 --red #e5484d，浅深同值（超字数提示等语义红一律走这里，不用 systemRed）。
    static var red: UIColor { UIColor(red: 0.898, green: 0.282, blue: 0.302, alpha: 1) }
    /// 图片上的深色衬底：固定黑色半透明（与 ink 不同——深色下 ink 是近白，白字会看不清）。
    static var scrim: UIColor { UIColor(white: 0, alpha: 0.6) }
    /// 网页 --blue：浅 #007aff / 深 #0a84ff（深色 G 通道精确 132/255，勿再写 0.52）。
    static var blue: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 10.0/255.0, green: 132.0/255.0, blue: 1.0, alpha: 1) : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1) } }
    /// 语义绿：网页 --green #2fbf71，深浅同值。
    static var green: UIColor { UIColor(red: 47.0/255.0, green: 191.0/255.0, blue: 113.0/255.0, alpha: 1) }
    /// 网页 --line：浅 #dbdbdb / 深 #3a3a40（深色带蓝偏，单 white 值复现不了）。
    static var line: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 58.0/255.0, green: 58.0/255.0, blue: 64.0/255.0, alpha: 1) : UIColor(white: 0.86, alpha: 1) } }
    static var bg: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? .black : .white } }
    /// 网页 --surface：浅 #fff / 深 #26262c。
    static var surface: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 38.0/255.0, green: 38.0/255.0, blue: 44.0/255.0, alpha: 1) : .white } }
    static var faint: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.96, alpha: 1) } }
    /// 网页 --hov：浅 rgba(17,17,20,.06) / 深 rgba(244,244,248,.08)（悬停/按压底色）。
    static var hov: UIColor { UIColor { t in t.userInterfaceStyle == .dark ? UIColor(red: 244.0/255.0, green: 244.0/255.0, blue: 248.0/255.0, alpha: 0.08) : UIColor(red: 17.0/255.0, green: 17.0/255.0, blue: 20.0/255.0, alpha: 0.06) } }
}

// MARK: - 图片地址

enum BearyImageURLs {
    static let base = "https://teddyhn.com"

    /// 日记图：key 是 R2 key（含 /）；thumb=true 取 key+'_t' 缩略图。
    static func imageURL(key: String, thumb: Bool) -> URL? {
        let full = thumb ? (key + "_t") : key
        let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? full
        return URL(string: base + "/beary/api/images/" + encoded)
    }

    /// 头像：服务端给的是 /beary/api/users/:id/avatar?v=N 这样的路径，拼域名；已是完整 URL 则原样用。
    static func avatarURL(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("http://") || p.hasPrefix("https://") { return URL(string: p) }
        if p.hasPrefix("/") { return URL(string: base + p) }
        return URL(string: base + "/" + p)
    }
}

// MARK: - 图片加载（内存缓存 + 取消旧任务）

final class BearyImageLoader {
    static let shared = BearyImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    @discardableResult
    func load(url: URL, completion: @escaping (UIImage?) -> Void) -> URLSessionDataTask? {
        if let img = cache.object(forKey: url.absoluteString as NSString) {
            completion(img)
            return nil
        }
        let task = session.dataTask(with: url) { [weak self] data, _, _ in
            var img: UIImage?
            if let data = data { img = UIImage(data: data) }
            if let img = img { self?.cache.setObject(img, forKey: url.absoluteString as NSString) }
            DispatchQueue.main.async { completion(img) }
        }
        task.resume()
        return task
    }
}

private var bearyImageTaskKey: UInt8 = 0

extension UIImageView {
    /// cell 复用时取消上一个未完成的下载，避免图片串位。
    func bearySetImage(url: URL?, placeholder: UIImage? = nil) {
        if let old = objc_getAssociatedObject(self, &bearyImageTaskKey) as? URLSessionDataTask {
            old.cancel()
        }
        self.image = placeholder
        guard let url = url else { return }
        let task = BearyImageLoader.shared.load(url: url) { [weak self] img in
            if let img = img { self?.image = img }
        }
        objc_setAssociatedObject(self, &bearyImageTaskKey, task, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - 时间与名字

enum BearyText {
    /// created_at 是毫秒时间戳。今天 → HH:mm；昨天 → 昨天 HH:mm；否则 M月d日 HH:mm。
    static func timeString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
            return fmt.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            fmt.dateFormat = "HH:mm"
            return "昨天 " + fmt.string(from: date)
        }
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: date)
    }

    /// 心情 key → 中文名（与网页 MOOD_DEFS 同集 40 种；前 32 带小熊、后 8 不带）。
    static let moodNames: [String: String] = [
        "agree": "嗯嗯", "happy": "开心", "applause": "为你鼓掌", "cheer": "加油",
        "comfort": "安慰", "confused": "迷惑", "love": "心动", "determined": "加把劲",
        "facepalm": "捂脸", "shy": "害羞", "goodnight": "晚安", "hug": "抱抱",
        "wink": "眨眼", "idea": "灵光一闪", "kiss": "亲一下", "thinking": "思考",
        "listening": "我在听", "lonely": "孤单", "speechless": "无语", "nope": "不嘛",
        "surprised": "惊讶", "pat": "摸摸头", "peek": "偷偷看", "sleepy": "困倦",
        "proud": "骄傲", "shrug": "没办法", "sorry": "对不起", "cry": "想哭",
        "angry": "生气", "thanks": "谢谢你", "zap": "带电", "wave": "挥挥手",
        "candle": "留一盏灯", "flower": "送你小花", "letter": "收到心意", "paperplane": "把烦恼寄走",
        "sprout": "慢慢来", "tea": "喝杯热茶", "umbrella": "给你撑伞", "wish": "愿你如愿",
    ]

    /// 天气 key → 中文名（与网页 WX_DEFS 同集 9 种）。
    static let weatherNames: [String: String] = [
        "sun": "晴", "cloud": "多云", "cloudy": "阴", "rain": "雨", "snow": "雪",
        "fog": "雾", "thunder": "雷阵雨", "wind": "风", "night": "夜晚",
    ]
}

// MARK: - 写接口响应模型（BearyAPI 用 convertFromSnakeCase 解码）

struct LikeResponse: Decodable {
    var ok: Bool?
    var liked: Bool?
    var count: Int?
}

struct BookmarkResponse: Decodable {
    var ok: Bool?
    var bookmarked: Bool?
}

struct EmoteResponse: Decodable {
    var ok: Bool?
    var emotes: [EmoteCount]?
}

struct UploadResponse: Decodable {
    var key: String?
}

struct CreateResponse: Decodable {
    var id: String?
    var publishAt: Int?
    var editDeadline: Int?
    var deduped: Bool?
}

// MARK: - BearyAPI 写接口扩展（端点均已在 teddy_beary/worker.js 后端核实）

extension BearyAPI {
    /// 点赞：liked=true 发 POST，liked=false 发 DELETE；响应带权威计数，前端一律以它覆盖本地计数。
    /// 未公开日记会 404；未登录 401（走 onUnauthorized）。
    func toggleLike(id: String, liked: Bool, completion: @escaping (Result<LikeResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/like", method: liked ? "POST" : "DELETE", completion: completion)
    }

    /// 收藏开关：POST 一次即取反；仅已公开日记可用。
    func toggleBookmark(id: String, completion: @escaping (Result<BookmarkResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/bookmark", method: "POST", completion: completion)
    }

    /// 回应：POST 同一 emote 即撤下；响应带聚合后的 emotes，前端一律以它覆盖。
    /// 产品规则“每人每篇只留一个回应”由调用方保证：贴新回应时先 POST 旧的撤下、再 POST 新的。
    func postEmote(id: String, emote: String, completion: @escaping (Result<EmoteResponse, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        request("/beary/api/entries/\(safe)/emote", method: "POST", jsonBody: ["emote": emote], completion: completion)
    }

    /// 图片上传：dataUrl 与 thumb 均为 data:image/jpeg;base64,...；单图 ≤5MB、缩略图 ≤2MB。
    /// 成功返回 R2 key（原图与缩略图共用该 key，缩略图另存 key+'_t'）。
    func uploadImage(dataUrl: String, width: Int, height: Int, thumbDataUrl: String?, completion: @escaping (Result<UploadResponse, APIError>) -> Void) {
        var body: [String: Any] = ["dataUrl": dataUrl, "w": width, "h": height]
        if let t = thumbDataUrl { body["thumb"] = t }
        request("/beary/api/images/upload", method: "POST", jsonBody: body, completion: completion)
    }

    /// 发帖：content 必填 ≤2000 字；images 是已上传的 R2 key 数组（须归属本人且存在）；
    /// mood/weather/quote_id 省略即不传（服务端 validMood/validWeather 对缺失值置 null，与网页同口径）；
    /// recipient_id 有值时必带 notify_recipient（1 开 / 0 关，网页同款）；client_req 须匹配
    /// ^[A-Za-z0-9_-]{8,64}$，用于发布幂等。
    /// 成功 201 返回 {id, publish_at, edit_deadline}；失败码：content required / content too long /
    /// invalid image ownership / image unavailable(409) / create_gap / create_day_limit /
    /// create_ip_limit(429) / create_dup / recipient_invalid。
    func publishEntry(content: String, images: [String], mood: String?, weather: String? = nil, quoteId: String? = nil, recipientId: Int? = nil, notifyRecipient: Int? = nil, clientReq: String, completion: @escaping (Result<CreateResponse, APIError>) -> Void) {
        var body: [String: Any] = ["content": content, "images": images, "client_req": clientReq]
        if let m = mood { body["mood"] = m }
        if let w = weather { body["weather"] = w }
        if let q = quoteId { body["quote_id"] = q }
        if let r = recipientId {
            body["recipient_id"] = r
            body["notify_recipient"] = notifyRecipient ?? 1
        }
        request("/beary/api/entries", method: "POST", jsonBody: body, completion: completion)
    }

    /// 编辑已发日记：PUT /beary/api/entries/:id，字段与网页编辑同款（content/images/mood/weather/quote_id；
    /// 写给与通知不在 PUT 字段里，发布即锁定、编辑不可改）。
    /// 服务端 15 分钟规则：已公开 403 'already public'、过编辑期 403 'edit window expired' 或
    /// 'already public or expired'；成功只返回 {ok: true}，调用方成功后自行重拉单篇。
    /// 图片须归属本人且存在，否则 400 'invalid image ownership' / 409 'image unavailable'。
    func updateEntry(id: String, content: String, images: [String], mood: String?, weather: String?, quoteId: String?, completion: @escaping (Result<Void, APIError>) -> Void) {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var body: [String: Any] = ["content": content, "images": images]
        if let m = mood { body["mood"] = m }
        if let w = weather { body["weather"] = w }
        if let q = quoteId { body["quote_id"] = q }
        requestVoid("/beary/api/entries/\(safe)", method: "PUT", jsonBody: body, completion: completion)
    }
}

// MARK: - 图片压缩（与网页编辑器同口径：原图最长边 1600、JPEG .85；缩略图最长边 480）

enum BearyImagePrep {
    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let longest = max(w, h)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// 返回 JPEG data 与压缩后宽高（像素数按原图比例换算，取整）。
    static func jpegData(_ image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.85) -> (data: Data, w: Int, h: Int)? {
        let img = resized(image, maxSide: maxSide)
        guard let data = img.jpegData(compressionQuality: quality) else { return nil }
        let scale = img.size.width > 0 ? (image.size.width / img.size.width) : 1
        let w = Int(round(image.size.width / scale))
        let h = Int(round(image.size.height / scale))
        return (data, max(w, 1), max(h, 1))
    }

    static func thumbData(_ image: UIImage, maxSide: CGFloat = 480) -> Data? {
        let img = resized(image, maxSide: maxSide)
        return img.jpegData(compressionQuality: 0.8)
    }

    static func dataURL(_ data: Data) -> String {
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}

/// 网页版同款图标入口（一比一图标替换批）。
/// 资产为 Assets.xcassets 内 icon_<名>（网页 beary-* sprite 渲染的黑色描边 PNG，
/// 与 emote/crown 同款 @1x/@2x/@3x 三档）。必须走本函数取图：UIButton.setImage
/// 不缩放图片，原始 72px 图会按 72pt 显示；本函数按目标 pt 尺寸重绘，
/// 等价于旧 SF SymbolConfiguration(pointSize:) 的显示尺寸。
/// 一律 alwaysTemplate + 调用方 tintColor 着色（与旧 SF 行为一致）。
enum BearyIconImages {
    static func image(named name: String, pointSize: CGFloat) -> UIImage? {
        guard let base = UIImage(named: name) else { return nil }
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let drawn = renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: size)) }
        return drawn.withRenderingMode(.alwaysTemplate)
    }
}
