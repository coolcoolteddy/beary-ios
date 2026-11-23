import UIKit

// ===== 广场轮播服务端配置（2026-11-23）=====
// GET /beary/api/carousel-config 下发页面清单，App 按清单组装轮播；
// 服务端已按 enabled + 时间规则（上海星期）过滤，客户端只管渲染。
// 拉取失败（离线/报错）用上次缓存的；第一次拉不到用内置默认
// （盲盒 / 精选 3 篇 / 历史上的今天），轮播永不空白、不闪退。
// 配置 5 分钟内不重复拉（管理端改完最迟 5 分钟生效，下次重建即取新值）。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await。

/// 轮播一页的配置。
struct BearyCarouselPageConfig: Codable {
    /// 页面类型。服务端发来未知类型时整行丢弃（旧版 App 不炸）。
    enum PageType: String, Codable {
        case featured
        case history
        case blindbox
        case announcement
    }

    var type: PageType
    var enabled: Bool
    var count: Int?
    var days: [Int]?

    init(type: PageType, enabled: Bool, count: Int?, days: [Int]?) {
        self.type = type
        self.enabled = enabled
        self.count = count
        self.days = days
    }

    enum CodingKeys: String, CodingKey {
        case type, enabled, count, days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let parsed = PageType(rawValue: rawType) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "未知轮播页类型")
        }
        type = parsed
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        days = try container.decodeIfPresent([Int].self, forKey: .days)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(days, forKey: .days)
    }
}

/// 轮播配置（一组页面清单）。解码宽容：pages 缺失/非法时为空数组，
/// 调用方视为空配置、回落内置默认；未知类型的行直接丢弃。
struct BearyCarouselConfig: Codable {
    var pages: [BearyCarouselPageConfig]

    init(pages: [BearyCarouselPageConfig]) {
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey {
        case pages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 逐行宽容解码：某一行非法（未知 type 等）只丢该行，不炸整份配置。
        let decoded = (try? container.decode([BearyFailablePage].self, forKey: .pages)) ?? []
        pages = decoded.compactMap { $0.base }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pages, forKey: .pages)
    }
}

/// 宽容解码包装：单行非法时 base 为 nil（整行丢弃），不炸整份配置。
private struct BearyFailablePage: Decodable {
    let base: BearyCarouselPageConfig?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        base = try? container.decode(BearyCarouselPageConfig.self)
    }
}

/// GET /beary/api/carousel-config 回包：{ ok, config, updated_at }。
/// BearyAPI 的 decoder 用 convertFromSnakeCase，updated_at 转 updatedAt。
private struct BearyCarouselConfigResponse: Decodable {
    let ok: Bool
    let config: BearyCarouselConfig?
    let updatedAt: Int?
}

enum BearyCarouselConfigLoader {
    /// 内置默认＝当前 App 行为：盲盒第一页、精选 3 篇、历史上的今天 1 页。
    static let defaultConfig = BearyCarouselConfig(pages: [
        BearyCarouselPageConfig(type: .blindbox, enabled: true, count: nil, days: nil),
        BearyCarouselPageConfig(type: .featured, enabled: true, count: 3, days: nil),
        BearyCarouselPageConfig(type: .history, enabled: true, count: nil, days: nil),
    ])

    private static let cacheKey = "beary.carousel.config.v1"
    private static let fetchedAtKey = "beary.carousel.config.v1.fetchedAt"
    /// 配置缓存有效期：5 分钟内不重复拉。
    private static let cacheTTLMs = 5 * 60 * 1000

    private static var inFlightCompletions: [(BearyCarouselConfig) -> Void]?

    static func cached() -> BearyCarouselConfig? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        guard let config = try? JSONDecoder().decode(BearyCarouselConfig.self, from: data), !config.pages.isEmpty else { return nil }
        return config
    }

    private static func save(_ config: BearyCarouselConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000), forKey: fetchedAtKey)
    }

    private static func isCacheFresh() -> Bool {
        let fetchedAt = UserDefaults.standard.object(forKey: fetchedAtKey) as? Int ?? 0
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return fetchedAt > 0 && nowMs - fetchedAt < cacheTTLMs
    }

    /// 拉取配置：缓存 5 分钟内有效时直接回包（不发请求）；否则发 GET，
    /// 成功写缓存后回包；失败回缓存或内置默认（永不回空配置）。
    /// 回调一律主线程。
    static func load(completion: @escaping (BearyCarouselConfig) -> Void) {
        if let cached = cached(), isCacheFresh() {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        if inFlightCompletions != nil {
            inFlightCompletions?.append(completion)
            return
        }
        inFlightCompletions = [completion]
        let finish: (BearyCarouselConfig) -> Void = { config in
            DispatchQueue.main.async {
                let waiting = inFlightCompletions ?? []
                inFlightCompletions = nil
                waiting.forEach { $0(config) }
            }
        }
        BearyAPI.shared.request("/beary/api/carousel-config", suppressUnauthorized: true) { (result: Result<BearyCarouselConfigResponse, APIError>) in
            switch result {
            case .success(let response):
                if response.ok, let config = response.config, !config.pages.isEmpty {
                    save(config)
                    finish(config)
                } else {
                    finish(cached() ?? defaultConfig)
                }
            case .failure:
                finish(cached() ?? defaultConfig)
            }
        }
    }
}
