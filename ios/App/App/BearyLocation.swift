import Foundation
import UIKit
import CoreLocation

// ===== 日记位置（批 E，2026-10-30）=====
// 口径（预览 v2 + v3，方案 A）：
// - 日记行只存两段文本：location_name（精确地点文本）、location_district（区级文本）。
// - 经纬度永不持久化：定位/搜索时坐标只在内存里走一次逆地理编码取地名，用完即弃；
//   地图渲染时按文本现场地理编码（见 BearyDiaryMapViewController，缓存只在内存、随页销毁）。
// - 展示层实时脱敏：库里保留精确值，非作者一律只渲染区级（公开、仅好友、
//   私密不分，精确位置只有作者本人在非公开篇可见）；公开翻回私密，精确位置
//   立即恢复（因为脱敏不在写库时做，翻转无需回写）。
// - 作者本人看自己的公开篇也只渲染区级（与他人所见文案一致，不再另附
//   “公开后他人仅见区级”提示行，2026-11-10 Li 定）；非公开篇作者本人才看精确名。
// - 他人视角 fail-closed：只有精确名、没有区级文本时，他人行直接不显示位置行，
//   绝不把精确名当区级兜底露出。

/// 编辑器/草稿/发布共用的位置值（只有文本，没有坐标）。
struct DiaryLocation: Equatable {
    var name: String?
    var district: String?

    var isEmpty: Bool {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty && d.isEmpty
    }

    init(name: String?, district: String?) {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = n.isEmpty ? nil : n
        self.district = d.isEmpty ? nil : d
    }

    init(entry: Entry) {
        self.init(name: entry.locationName, district: entry.locationDistrict)
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
