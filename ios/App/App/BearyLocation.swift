import Foundation
import UIKit
import CoreLocation

// ===== 日记位置（批 E，2026-10-30）=====
// 口径（预览 v2 + v3，方案 A；经纬度口径 2026-11-14 Li 改版，见下）：
// - 日记行存两段文本＋经纬度：location_name（精确地点文本）、location_district（区级文本）、
//   location_lat / location_lng（2026-11-14 Li 定，推翻方案 A“只存地点文字、不存经纬度”口径）。
// - 显示层按当前系统语言逆地理编码取地名（见 BearyLocationDisplayNames），切语言后地名跟着变；
//   逆地理编码失败／离线回退显示原存地名；无经纬度的旧日记只显示原存地名，不动。
// - 地图渲染时优先用存量经纬度直接落钉；无坐标的旧日记仍按文本现场地理编码
//   （见 BearyDiaryMapViewController，缓存只在内存、随页销毁）。
// - 展示层实时脱敏：库里保留精确值，非作者一律只渲染区级（公开、仅好友、
//   私密不分，精确位置只有作者本人在非公开篇可见）；公开翻回私密，精确位置
//   立即恢复（因为脱敏不在写库时做，翻转无需回写）。
// - 作者本人看自己的公开篇也只渲染区级（与他人所见文案一致，不再另附
//   “公开后他人仅见区级”提示行，2026-11-10 Li 定）；非公开篇作者本人才看精确名。
// - 他人视角 fail-closed：只有精确名、没有区级文本时，他人行直接不显示位置行，
//   绝不把精确名当区级兜底露出。

/// 编辑器/草稿/发布共用的位置值（两段文本＋经纬度）。
struct DiaryLocation: Equatable {
    var name: String?
    var district: String?
    /// 2026-11-14 Li 定：地点改存经纬度（推翻方案 A 只存文本口径）；写路径下坐标
    /// 恒随文本一起存（定位／搜索结果自带坐标）；显示层按当前语言逆地理编码取地名。
    /// 埋藏定位仍只存区级名、不存经纬度（见 BearyTimeCapsule），与本字段无关。
    var latitude: Double?
    var longitude: Double?

    var isEmpty: Bool {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty && d.isEmpty
    }

    /// 坐标是否齐全可用：写路径下坐标恒随文本一起存，旧日记无坐标时为 false；
    /// (0,0) 不是真实地点，按无效处理。
    var hasCoordinates: Bool {
        guard let lat = latitude, let lng = longitude else { return false }
        return (-90...90).contains(lat) && (-180...180).contains(lng) && (lat != 0 || lng != 0)
    }

    init(name: String?, district: String?, latitude: Double? = nil, longitude: Double? = nil) {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = n.isEmpty ? nil : n
        self.district = d.isEmpty ? nil : d
        self.latitude = latitude
        self.longitude = longitude
    }

    init(entry: Entry) {
        self.init(name: entry.locationName, district: entry.locationDistrict, latitude: entry.locationLatitude, longitude: entry.locationLongitude)
    }
}

enum BearyLocationDisplay {
    /// 作者本人判定：服务端 isMine 为真，或作者 id 等于当前登录用户 id。
    /// isMine 缺失且未登录时一律按他人算（fail-closed，不凭空给精确值）。
    static func viewerIsAuthor(entry: Entry) -> Bool {
        if entry.isMine == true { return true }
        if let authorId = entry.authorId, let viewerId = SessionManager.shared.currentUser?.id {
            return authorId == viewerId
        }
        return false
    }

    /// 卡片/详情/时间线/地图列表共用的位置行文案。
    /// 返回 nil = 不显示位置行（无位置、或他人视角下只有精确名无区级、
    /// 或作者本人看自己的公开篇但无区级）。
    /// 口径（2026-11-10 Li 定）：公开篇作者本人也只看区级（与他人视角
    /// 看到的文案一致，不再另附“公开后他人仅见区级”提示行）；非公开篇
    /// 作者本人看精确名；非作者一律只到区级。
    static func display(entry: Entry) -> String? {
        return display(
            location: DiaryLocation(entry: entry),
            isPublic: BearyEphemeral.isEffectivelyPublic(entry),
            viewerIsAuthor: viewerIsAuthor(entry: entry)
        )
    }

    static func display(location: DiaryLocation, isPublic: Bool, viewerIsAuthor: Bool) -> String? {
        if location.isEmpty { return nil }
        if !viewerIsAuthor {
            // 非作者一律只到区级：不依赖日记是否公开——仅好友篇 isPublic
            // 为 false，旧口径会落进精确名分支；没有区级就不显示，绝不
            // 回退到精确名。
            return location.district
        }
        if isPublic {
            // 作者本人看自己的公开篇：直接显示区级（与他人视角一致）；
            // 无区级不显示，不回退到精确名。
            return location.district
        }
        // 作者本人看自己的非公开篇（私密／仅好友／限时）：精确名优先，无名退区级。
        return location.name ?? location.district
    }

    /// 区级文本派生（逆地理编码/搜索 placemark 共用）：
    /// 中国地址 subAdministrativeArea 即区/县；缺失时退市级、再退省级，
    /// 绝不把街道/POI 名当区级用。
    static func district(from placemark: CLPlacemark) -> String? {
        for candidate in [placemark.subAdministrativeArea, placemark.locality, placemark.administrativeArea] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// 按当前系统语言重取地名（2026-11-14 Li 定，推翻方案 A“只存地点文字、不存经纬度”口径）：
/// 日记地点改存经纬度；显示层按当前语言逆地理编码取地名，切语言后地名跟着变；
/// 逆地理编码失败／离线时回退显示原存地名（调用方保留同步算出的原存文本行）；
/// 无经纬度的旧日记不解析，只显示原存地名。
/// 地名派生与写路径同口径（placemark.name + district(from:)），只差语言是当前的；
/// 可见性脱敏与同步 display 完全一致（公开→区级、私密→精确、他人→区级）。
enum BearyLocationDisplayNames {
    /// 坐标＋语言 → 解析出的（精确名，区级）。只活在内存里，随进程销毁；
    /// 切语言后键里的语言变了，旧缓存自然不再命中。失败不缓存，下次渲染再试。
    private static var cache: [String: (name: String?, district: String?)] = [:]
    /// 在途解析的回调表：同坐标同语言只发一次请求，多处共用回包。
    private static var pending: [String: [((name: String?, district: String?)?) -> Void]] = [:]

    private static func cacheKey(latitude: Double, longitude: Double) -> String {
        let lang = Locale.preferredLanguages.first ?? Locale.current.identifier
        return "\(latitude),\(longitude)|\(lang)"
    }

    /// 当前语言的地名（精确名，区级）：有经纬度时逆地理编码取当语言地名；
    /// 失败／无经纬度／解析出空地名时回 nil，调用方保留原存文本。
    /// 回调总在主线程、总异步投递（缓存命中也不例外，调用方在 cellForRow 内调也安全）；
    /// 同一行重复渲染共用一次在途请求。调用方须在主线程调用。
    static func resolvedNames(for entry: Entry, completion: @escaping ((name: String?, district: String?)?) -> Void) {
        guard let lat = entry.locationLatitude, let lng = entry.locationLongitude,
              (-90...90).contains(lat), (-180...180).contains(lng), (lat != 0 || lng != 0) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let key = cacheKey(latitude: lat, longitude: lng)
        if let cached = cache[key] {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        if pending[key] != nil {
            pending[key]?.append(completion)
            return
        }
        pending[key] = [completion]
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng)) { placemarks, _ in
            DispatchQueue.main.async {
                let callbacks = pending.removeValue(forKey: key) ?? []
                guard let placemark = placemarks?.first else {
                    callbacks.forEach { $0(nil) }
                    return
                }
                let name = placemark.name
                let district = BearyLocationDisplay.district(from: placemark)
                let resolved = DiaryLocation(name: name, district: district, latitude: lat, longitude: lng)
                guard !resolved.isEmpty else {
                    callbacks.forEach { $0(nil) }
                    return
                }
                let names = (name, district)
                cache[key] = names
                callbacks.forEach { $0(names) }
            }
        }
    }

    /// 当前语言的位置行：有经纬度时逆地理编码取当语言地名，成功即按显示口径算行文；
    /// 失败／无经纬度时回 nil，调用方保留原存文本行。回调总在主线程、总异步投递。
    static func displayLine(for entry: Entry, completion: @escaping (String?) -> Void) {
        resolvedNames(for: entry) { names in
            guard let names = names else {
                completion(nil)
                return
            }
            let line = BearyLocationDisplay.display(
                location: DiaryLocation(name: names.name, district: names.district, latitude: entry.locationLatitude, longitude: entry.locationLongitude),
                isPublic: BearyEphemeral.isEffectivelyPublic(entry),
                viewerIsAuthor: BearyLocationDisplay.viewerIsAuthor(entry: entry))
            completion(line)
        }
    }
}

/// 地图聚合组：本人按精确地点名 + 区级聚合（同名换区拆成不同组；
/// 只有地点名的记录单独成组，不猜它属于哪个区），他人按区级聚合。
/// 聚合是 Entry 列表的纯函数（不另建缓存、不轮询），可见性翻转/删除/
 /// 回收站/注销的同步由调用方重拉列表后重算自然达成，不存在过期地图缓存。
struct BearyLocationMapGroup {
    /// 稳定组 ID（P1-6）：本人组 = 名 + 区（同名换区是不同 ID）、
    /// 只有地点名时 ID 只有名、无名退区级；他人组恒为区级。
    /// n:/d: 前缀防名-only 与区-only 同文本撞 ID（如地点名恰好
    /// 等于某区级文本）。查组、缓存键、编码查询一律按 id；
    /// key 只作展示文本，不作身份——同名不同区的两组 key 可以相同。
    let id: String
    /// 展示文本：本人 = 精确地点名（无名退区级），他人 = 区级。
    let key: String
    let entries: [Entry]
    /// 他人组恒为真（键已是区级）；本人组为假（键是精确文本，见方案 A 漂移说明）。
    let isDistrictOnly: Bool

    var count: Int { entries.count }
}

enum BearyLocationMap {
    /// 聚合入口。过滤规则（与展示层同口径）：
    /// - 无位置（名与区双空）不进地图、不留空点；
    /// - 私密占位（placeholder）不进；
    /// - 他人视角：只进有效公开篇，且必须有区级（无区级不进不计入）；
    /// - 本人视角：私密 + 公开都进。
    static func groups(entries: [Entry], viewerIsAuthor: Bool) -> [BearyLocationMapGroup] {
        var buckets: [String: [Entry]] = [:]
        var displayKeys: [String: String] = [:]
        var districtOnlyIds = Set<String>()
        for entry in entries {
            if entry.placeholder == true { continue }
            let location = DiaryLocation(entry: entry)
            if location.isEmpty { continue }
            if viewerIsAuthor {
                // P1-6：同名不同区拆组——ID 含区级；只有地点名时
                // ID 只有名，不猜它属于哪个区（与有名有区的组互不合并）；
                // 无名时退区级。区级与名相同时不再拼区（无增量信息）。
                let id: String
                let displayKey: String
                if let name = location.name {
                    displayKey = name
                    if let district = location.district, district != name {
                        id = "n:\(name)\u{1F}d:\(district)"
                    } else {
                        id = "n:\(name)"
                    }
                } else {
                    // 走到这里 name 已为 nil；isEmpty 已排除，故 district 必非空。
                    // 仍用 guard 收口：万一 district 为空则不进组。
                    guard let district = location.district else { continue }
                    displayKey = district
                    id = "d:\(district)"
                }
                buckets[id, default: []].append(entry)
                displayKeys[id] = displayKey
            } else {
                guard BearyEphemeral.isEffectivelyPublic(entry), let district = location.district else { continue }
                let id = "d:\(district)"
                buckets[id, default: []].append(entry)
                displayKeys[id] = district
                districtOnlyIds.insert(id)
            }
        }
        return buckets.map { id, list in
            BearyLocationMapGroup(id: id, key: displayKeys[id] ?? id, entries: list, isDistrictOnly: districtOnlyIds.contains(id))
        }.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.key != b.key { return a.key < b.key }
            return a.id < b.id
        }
    }
}

/// 定位图标铁律（Li 2026-10-30 新令）：一律用 beary-ui 官方包，不许自绘、不用 SF Symbol
/// 做主图标顶替。本函数只返回官方 icon_location，不设任何回退：资产缺失时返回 nil，
/// 调用方按占位处理（按钮保留可点 + VoiceOver 文案，不画替代图、不上线替代视觉）。
/// 已核验：基线 Assets 内确有 icon_location.imageset（@1x/@2x/@3x、template 渲染，
/// 单线手绘定位针），故本批实际不缺图标，nil 分支只是防资产被误删的 fail-safe。
enum BearyLocationIcon {
    static func image(pointSize: CGFloat) -> UIImage? {
        return BearyIconImages.image(named: "icon_location", pointSize: pointSize)
    }
}

// MARK: - 时间胶囊 v1（2026-11-12，最小版）

/// 胶囊判定与本地解锁口径（纯函数 + 一次定位取区级，不新文件）。
/// 字段口径以后端已部署的为准：is_capsule / capsule_unlock_at（毫秒戳）/
/// capsule_district（区级文本）；旧分支的 capsule_buried /
/// capsule_unlock_date 是错名，绝不引用。
enum BearyTimeCapsule {
    /// 地图渲染资格：埋了（isCapsule==1）且公开态（visibility public 或
    /// isPublic；限时过期按 BearyEphemeral 口径算不公开）。公开转私密
    /// 后资格即失，标记随重算下线，不改服务端。
    static func isPublicCapsule(_ entry: Entry) -> Bool {
        guard entry.isCapsuleBuried else { return false }
        guard entry.visibility == "public" || entry.isPublic == true else { return false }
        return !BearyEphemeral.isExpired(entry)
    }

    /// 本地解锁判定：时间到了 AND 当前区级与埋藏区级去空白后精确相等。
    /// 不做包含／模糊匹配；取不到当前区级时按未解锁处理（fail-closed）。
    static func isUnlocked(_ entry: Entry, currentDistrict: String?, nowMs: Int? = nil) -> Bool {
        guard let unlockAt = entry.capsuleUnlockAt else { return false }
        let now = nowMs ?? Int(Date().timeIntervalSince1970 * 1000)
        guard now >= unlockAt else { return false }
        guard let current = currentDistrict?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty,
              let buried = entry.capsuleDistrict?.trimmingCharacters(in: .whitespacesAndNewlines), !buried.isEmpty else { return false }
        return current == buried
    }

    /// 解锁日期文案：与现有日期文案同格式（yyyy年M月d日）。
    static func unlockDateText(_ entry: Entry) -> String? {
        guard let unlockAt = entry.capsuleUnlockAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(unlockAt) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 当前区级一次定位＋逆地理编码：只取区级文本，不存坐标、不上传、
    /// 不写盘。取不到／无权限时回 nil，调用方按未解锁处理。
    static func fetchCurrentDistrict(completion: @escaping (String?) -> Void) {
        BearyOneShotLocation.request { result in
            switch result {
            case .coordinate(let latitude, let longitude):
                let geocoder = CLGeocoder()
                geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)) { placemarks, _ in
                    DispatchQueue.main.async {
                        completion(placemarks?.first.flatMap { BearyLocationDisplay.district(from: $0) })
                    }
                }
            case .denied, .unavailable:
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}

// MARK: - 天气 GPS 一次定位（2026-11-04）

/// 一次定位结果：只给调用方经纬度数值，不暴露 CLLocation 类型；
/// denied = 用户拒绝/受限（不再弹系统框）；unavailable = 定位失败/超时。
enum BearyOneShotLocationResult {
    case coordinate(latitude: Double, longitude: Double)
    case denied
    case unavailable
}

/// 天气钮专用一次定位：复用地点气泡同款权限流程（未决定→请求授权，已允许→
/// requestLocation，拒绝/受限→直接回落），不持续定位、不缓存坐标、不碰日记。
/// 完成回调恰好一次：成功、拒绝、失败、定位阶段超时（10 秒）任一先到即结算；
/// 实例靠静态表自持到结算，调用方无需持有。
/// R22 #11：授权等待与定位等待分阶段计时——等用户答权限框时不计时，授权通过
/// 后发出 requestLocation 时才启动 10 秒定位超时；弹窗里停留再久，同意后本次
/// 仍走 GPS，不直接回落 IP。拒绝/受限仍立即结算 .denied。
final class BearyOneShotLocation: NSObject, CLLocationManagerDelegate {
    private static var active = [BearyOneShotLocation]()
    private static let timeout: TimeInterval = 10

    private let manager = CLLocationManager()
    private var completion: ((BearyOneShotLocationResult) -> Void)?
    private var finished = false
    /// R22 #11：定位阶段是否已启动（requestLocation + 超时计时只做一次）。
    private var locationPhaseStarted = false

    static func request(completion: @escaping (BearyOneShotLocationResult) -> Void) {
        let req = BearyOneShotLocation(completion: completion)
        active.append(req)
        req.start()
    }

    private init(completion: @escaping (BearyOneShotLocationResult) -> Void) {
        self.completion = completion
        super.init()
    }

    private func start() {
        manager.delegate = self
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            // R22 #11：只等授权，不启动超时计时——用户读权限说明再久，
            // 同意后仍进定位阶段；计时见 beginLocationPhase()。
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationPhase()
        case .denied, .restricted:
            finish(with: .denied)
        @unknown default:
            finish(with: .unavailable)
        }
    }

    /// 定位阶段：发出 requestLocation，并从此刻起 10 秒无结果即按失败结算，
    /// 调用方走 IP 回落。只启动一次（授权回调可能多次触发）。
    private func beginLocationPhase() {
        guard !locationPhaseStarted else { return }
        locationPhaseStarted = true
        manager.requestLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish(with: .unavailable)
        }
    }

    private func finish(with result: BearyOneShotLocationResult) {
        guard !finished else { return }
        finished = true
        manager.delegate = nil
        manager.stopUpdatingLocation()
        Self.active.removeAll { $0 === self }
        completion?(result)
        completion = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !finished else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocationPhase()
        case .denied, .restricted:
            finish(with: .denied)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !finished, let coord = locations.last?.coordinate else { return }
        finish(with: .coordinate(latitude: coord.latitude, longitude: coord.longitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .unavailable)
    }
}
