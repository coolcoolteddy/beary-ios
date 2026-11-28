import Network
import UIKit

// ===== 设置页重组（2026-11-19 Li 定版，七组）：新偏好集中存放 =====
// 铁律：新功能都要真功能，不能写死假值。本文件只存偏好键与读取口径，
// 真实行为由各调用点实现（图片加载、GIF、实况、定位/天气、语言、主题）。

/// 流量节省程序（数据用量页，总开关，默认关）。
/// 开了之后：时间线与详情的图片只加载缩略图（见卡片/详情渲染点）、
/// 不预加载后面的图片（见 BearyImagePrefetcher）、GIF 只显示第一帧
/// （见 BearyInlineGIFOverlay）、实况照片不自动播（见 BearyLivePhotoView）。
enum BearyDataSaver {
    private static let key = "beary_data_saver_enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

/// 高画质图片（数据用量页）：在什么网络下拉原图。
/// cellularOrWifi = 使用蜂窝或无线网络；wifiOnly = 仅无线网络；off = 关闭。
/// 关闭时时间线/详情只下缩略图（与流量节省程序同款缩略图路径），点开大图仍下原图。
enum BearyHiResImagePolicy: String {
    case cellularOrWifi = "cellular_or_wifi"
    case wifiOnly = "wifi_only"
    case off = "off"

    private static let key = "beary_hires_image_policy"

    static var current: BearyHiResImagePolicy {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = BearyHiResImagePolicy(rawValue: raw) else { return .cellularOrWifi }
        return value
    }

    static func setCurrent(_ value: BearyHiResImagePolicy) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }

    /// 当前网络下是否允许拉原图（只看网络类型，不看流量节省程序；
    /// 调用点先判流量节省程序，再判本策略）。
    static var allowsOriginalOnCurrentNetwork: Bool {
        switch current {
        case .cellularOrWifi:
            return true
        case .wifiOnly:
            return BearyNetworkReachability.isOnWiFi
        case .off:
            return false
        }
    }
}

/// 上传画质（数据用量页）：新图按此档定上传方式。原图仅 Plus——起传时
/// 由 BearyPlusGate 把关，非 Plus 静默按压缩走，不改本值；单张原图超
/// 5MB 仍自动按压缩上传。只存本地，不同步服务端；默认压缩。
enum BearyUploadQuality: String {
    case original = "original"
    case compressed = "compressed"

    private static let key = "beary_upload_quality"

    static var current: BearyUploadQuality {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = BearyUploadQuality(rawValue: raw) else { return .compressed }
        return value
    }

    static func setCurrent(_ value: BearyUploadQuality) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }

    /// 新图与旧草稿未定方式的图按此档定上传方式。
    static var modeForNewImage: BearyUploadMode {
        current == .original ? .original : .compressed
    }
}

/// 当前是否 Wi-Fi（只读系统状态，不写档）。
/// NWPathMonitor 在主线程外回调，状态经串行队列同步读；首报未到前按非 Wi-Fi
/// 保守处理（流量策略向省取严）。
enum BearyNetworkReachability {
    private static let monitor = NWPathMonitor()
    private static let queue = DispatchQueue(label: "com.beary.network-reachability")
    private static var started = false
    private static var onWiFi = false

    static func startIfNeeded() {
        queue.sync {
            guard !started else { return }
            started = true
            monitor.pathUpdateHandler = { path in
                queue.async { onWiFi = path.usesInterfaceType(.wifi) }
            }
            monitor.start(queue: queue)
        }
    }

    static var isOnWiFi: Bool {
        startIfNeeded()
        return queue.sync { onWiFi }
    }
}

/// 自动播放实况（数据用量页，默认关）。
/// 开了之后时间线卡片与详情页里的实况照片就绪后自动播一次；
/// 关了只走长按播放（现行行为）。流量节省程序开了时强制不自动播。
enum BearyLivePhotoAutoplay {
    private static let key = "beary_live_photo_autoplay_enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }

    /// 实际是否自动播：开关开且流量节省程序关。
    static var shouldAutoplay: Bool {
        isEnabled && !BearyDataSaver.isEnabled
    }
}

/// 自动获取定位 / 自动获取天气（隐私页，默认开，现行行为不变）。
/// 关了之后：天气钮不再自动取数（只开选择器手动选）；定位流程不再发 GPS
/// 请求（天气回落走 IP 链路，地点选择器“当前位置”行隐藏，搜地名仍可用）。
enum BearyAutoFetch {
    private static let locationKey = "beary_auto_fetch_location_enabled"
    private static let weatherKey = "beary_auto_fetch_weather_enabled"

    /// 未写过档时默认开（现行行为）；写过档按档走。
    static var isLocationEnabled: Bool {
        UserDefaults.standard.object(forKey: locationKey) as? Bool ?? true
    }

    static var isWeatherEnabled: Bool {
        UserDefaults.standard.object(forKey: weatherKey) as? Bool ?? true
    }

    static func setLocationEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: locationKey)
    }

    static func setWeatherEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: weatherKey)
    }
}

/// 定位地址精度（隐私页，七档，默认区县，与现行“公开只显示到区级”一致）。
/// 档位按精度级别叫，国外按当地同级对应（区县档国外对应郡/区，街道档对应街名）。
/// 精度要真生效：后端按精度截断存储/展示的地址（见服务端 diff），App 显示层
/// 对作者本人非公开篇同样按精度封顶（见 BearyLocationDisplay）。
enum BearyLocationPrecision: String, CaseIterable {
    /// 地球：不显示任何位置。
    case earth = "earth"
    /// 地区/大洲：只显示大区一级（省/州）。
    case region = "region"
    /// 国家：只显示国家。
    case country = "country"
    /// 城市：只显示城市。
    case city = "city"
    /// 区县：只显示到区县（默认）。
    case district = "district"
    /// 街道：只显示到街道（街名）。
    case street = "street"
    /// 详细地址：完整地点名。
    case detail = "detail"

    static let key = "beary_location_precision"

    static var current: BearyLocationPrecision {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = BearyLocationPrecision(rawValue: raw) else { return .district }
        return value
    }

    static func setCurrent(_ value: BearyLocationPrecision) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        // 精度偏好须同步到服务端（后端按它截断存储/展示）；
        // 离线/失败时只记本地，下次进隐私页重发（见隐私子页）。
        BearyAPI.shared.saveLocationPrecision(value.rawValue) { _ in }
    }

    var title: String {
        switch self {
        case .earth: return "地球"
        case .region: return "地区/大洲"
        case .country: return "国家"
        case .city: return "城市"
        case .district: return "区县"
        case .street: return "街道"
        case .detail: return "详细地址"
        }
    }

    /// 精度级别（越小越粗）：比较用。地球 0 … 详细地址 6。
    var level: Int {
        switch self {
        case .earth: return 0
        case .region: return 1
        case .country: return 2
        case .city: return 3
        case .district: return 4
        case .street: return 5
        case .detail: return 6
        }
    }

    /// 该档位下作者本人非公开篇能看到的最细文本（App 显示层封顶用；
    /// 服务端对他人与列表做同款截断，见服务端 diff）。
    /// country/region/city/street 取发布时随地点一起存的 placemark 字段，
    /// 缺字段时向粗回退（绝不拿精确名凑数）。
    func displayText(for location: DiaryLocation) -> String? {
        switch self {
        case .earth:
            return nil
        case .region:
            return location.region ?? location.country
        case .country:
            return location.country
        case .city:
            return location.city ?? location.region ?? location.country
        case .district:
            return location.district
        case .street:
            return location.street ?? location.district
        case .detail:
            return location.name ?? location.district
        }
    }

    /// 该档位下公开篇的位置行文本（作者本人看自己的公开篇与他人视角一致）：
    /// 精度封顶后的最细地域文本，精确名不进公开行；地球档不显示。
    func areaText(for location: DiaryLocation) -> String? {
        switch self {
        case .earth:
            return nil
        case .region:
            return location.region ?? location.country
        case .country:
            return location.country
        case .city:
            return location.city ?? location.region ?? location.country
        case .district:
            return location.district
        case .street, .detail:
            return location.street ?? location.district
        }
    }
}

/// 主题（通用 → 主题子页）：跟随系统（默认开）＋浅色/深色。
/// 与旧三段滑块同款持久化与应用路径（beary_theme_mode + 窗口 override）。
enum BearyTheme {
    static let defaultsKey = "beary_theme_mode"

    static var mode: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? "system"
    }

    static func apply(mode: String, window: UIWindow?) {
        UserDefaults.standard.set(mode, forKey: defaultsKey)
        // 与 SceneDelegate.bearyUserInterfaceStyle 同款映射（该函数是
        // SceneDelegate 私有，本文件内联同一份三行映射，不另起口径）。
        let style: UIUserInterfaceStyle
        switch mode {
        case "light": style = .light
        case "dark": style = .dark
        default: style = .unspecified
        }
        window?.overrideUserInterfaceStyle = style
    }
}

/// 语言（通用 → 语言子页）：跟随系统 / 中国大陆（强制简体中文）/ English（强制英文）。
/// 实现：Bundle 子类覆盖 localizedString，切换后重建根界面即时生效，
/// 不靠重启、不靠退出重进。String Catalog（.xcstrings）编译后走
/// Bundle.main 的字符串表，子类覆盖对其生效。
enum BearyAppLanguage {
    enum Mode: String {
        /// 跟随系统语言。
        case system = "system"
        /// 强制简体中文。
        case mainland = "zh-Hans"
        /// 强制英文。
        case english = "en"
    }

    private static let key = "beary_app_language"
    static let didChangeNotification = Notification.Name("bearyAppLanguageDidChange")

    static var mode: Mode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let value = Mode(rawValue: raw) else { return .system }
        return value
    }

    /// 强制语言对应的 bundle（跟随系统时为 nil，走系统默认）。
    static var forcedBundle: Bundle? {
        switch mode {
        case .system:
            return nil
        case .mainland:
            guard let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj") else { return nil }
            return Bundle(path: path)
        case .english:
            guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
            return Bundle(path: path)
        }
    }

    /// 切语言：写档 → 换 Bundle.main 的类（只换一次）→ 发广播重建根界面。
    /// Bundle.main 的类只在首次调用时换（object_setClass 重复调用无害，
    /// 但只换一次更稳）；已换过类时只更新 forcedBundle 的读取（读 mode 实时算）。
    static func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        UserDefaults.standard.set(newMode.rawValue, forKey: key)
        installBundleOverrideIfNeeded()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static var bundleOverrideInstalled = false

    static func installBundleOverrideIfNeeded() {
        guard !bundleOverrideInstalled else { return }
        bundleOverrideInstalled = true
        object_setClass(Bundle.main, BearyLanguageBundle.self)
    }
}

/// Bundle.main 的语言覆盖子类：强制简体中文时走 zh-Hans.lproj，
/// 强制英文时走 en.lproj，否则走系统默认。只覆盖 localizedString 一个入口。
final class BearyLanguageBundle: Bundle {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let forced = BearyAppLanguage.forcedBundle {
            return forced.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}
