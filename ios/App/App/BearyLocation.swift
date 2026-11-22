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
// - 展示层实时脱敏（2026-11-19 七组版，定位地址精度七档）：
//   服务端按作者精度截断存储与展示（细于精度的文本不入库、列表/详情/搜索
//   下发时再截断一次）；非作者与作者本人看自己的公开篇看到的文案一致——
//   截断后的最细地域文本（精确名不进公开行）；非公开篇作者本人按自己的
//   精度封顶（默认区县；地球档不显示位置行）。公开翻回私密，精确位置
//   立即恢复（因为脱敏不在写库时做，翻转无需回写）。
// - 作者本人看自己的公开篇也只渲染截断后的地域文本（与他人所见文案一致，
//   不再另附“公开后他人仅见区级”提示行，2026-11-10 Li 定）。
// - 他人视角 fail-closed：只有精确名、没有地域文本时，他人行直接不显示位置行，
//   绝不把精确名当地域文本兜底露出。

/// 编辑器/草稿/发布共用的位置值（两段文本＋经纬度）。
struct DiaryLocation: Equatable {
    var name: String?
    var district: String?
    /// 2026-11-19 七组版：定位地址精度分级字段（发布时随地点一起存，
    /// 取自 placemark；缺字段时显示层向粗回退，绝不拿精确名凑数）。
    /// country：国家；region：省/州（地区/大洲档）；city：城市；
    /// street：街道名（街名，不含门牌号）。
    var country: String?
    var region: String?
    var city: String?
    var street: String?
    /// 2026-11-14 Li 定：地点改存经纬度（推翻方案 A 只存文本口径）；写路径下坐标
    /// 恒随文本一起存（定位／搜索结果自带坐标）；显示层按当前语言逆地理编码取地名。
    var latitude: Double?
    var longitude: Double?

    var isEmpty: Bool {
        // 2026-11-19 七组版：精度分级字段也是位置——只剩国家/地区时仍算有位置。
        let fields = [name, district, country, region, city, street]
        return fields.allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 坐标是否齐全可用：写路径下坐标恒随文本一起存，旧日记无坐标时为 false；
    /// (0,0) 不是真实地点，按无效处理。
    var hasCoordinates: Bool {
        guard let lat = latitude, let lng = longitude else { return false }
        return (-90...90).contains(lat) && (-180...180).contains(lng) && (lat != 0 || lng != 0)
    }

    init(name: String?, district: String?, latitude: Double? = nil, longitude: Double? = nil, country: String? = nil, region: String? = nil, city: String? = nil, street: String? = nil) {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let d = (district ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = n.isEmpty ? nil : n
        self.district = d.isEmpty ? nil : d
        func clean(_ value: String?) -> String? {
            let t = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        self.country = clean(country)
        self.region = clean(region)
        self.city = clean(city)
        self.street = clean(street)
        self.latitude = latitude
        self.longitude = longitude
    }

    init(entry: Entry) {
        self.init(name: entry.locationName, district: entry.locationDistrict, latitude: entry.locationLatitude, longitude: entry.locationLongitude, country: entry.locationCountry, region: entry.locationRegion, city: entry.locationCity, street: entry.locationStreet)
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
    /// 返回 nil = 不显示位置行（无位置、或他人视角下只有精确名无地域文本、
    /// 或作者本人看自己的公开篇但无地域文本）。
    /// 口径（2026-11-19 七组版，定位地址精度）：非作者与作者本人看自己的公开篇
    /// 看到的文案一致——服务端按作者精度截断后的最细地域文本（精确名不进公开行）；
    /// 非公开篇作者本人按自己的精度封顶（默认区县；地球档不显示位置行）。
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
            // 非作者：显示服务端按作者精度截断后的最细地域文本（细→粗：街道／区县／
            // 城市／地区／国家）；精确名不进他人行（与旧口径一致）。
            return location.street ?? location.district ?? location.city ?? location.region ?? location.country
        }
        if isPublic {
            // 作者本人看自己的公开篇：与他人视角一致——按自己的精度封顶后的最细地域文本
            // （逆地理编码路径也经此封顶，不会绕过服务端的截断）。
            return BearyLocationPrecision.current.areaText(for: location)
        }
        // 作者本人看自己的非公开篇（私密／仅好友／限时）：按自己的定位地址精度
        // 封顶（默认区县，与公开口径一致；地球档不显示位置行；缺字段向粗回退）。
        return BearyLocationPrecision.current.displayText(for: location)
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

    /// 写路径地名派生（搜索结果/逆地理编码/附近 POI 共用）：优先用
    /// placemark.name，缺失时拼路名＋门牌号；结果统一过地址去重
    /// （见 dedupedAddressName），不把重复段存进日记。
    static func name(from placemark: CLPlacemark) -> String? {
        if let name = placemark.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return dedupedAddressName(name)
        }
        let parts = [placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return dedupedAddressName(parts.joined(separator: " "))
    }

    /// 地址去重（2026-11-18 定位重做）：同一段地址不得重复出现（如
    /// “朝晖路 248 弄 248 弄 21 号”里的“248 弄”）。只处理两种实测形态：
    /// 按空白分词后紧邻重复的词组、与无空白时紧邻重复的字符段；重复段
    /// 须含数字才删（防误删正常叠词），最多清两轮。
    static func dedupedAddressName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<2 {
            let deduped = dedupedAddressNameOnce(text)
            guard deduped != text else { break }
            text = deduped
        }
        return text
    }

    private static func dedupedAddressNameOnce(_ text: String) -> String {
        // 形态一：按空白分词，紧邻重复的词组（含数字才删，如“248 弄”）。
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.count >= 2 {
            for count in (1...min(3, tokens.count / 2)).reversed() {
                for start in 0...(tokens.count - count * 2) {
                    let first = tokens[start..<(start + count)]
                    let second = tokens[(start + count)..<(start + count * 2)]
                    guard first.elementsEqual(second) else { continue }
                    let joined = first.joined(separator: " ")
                    guard joined.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
                    var result = tokens
                    result.removeSubrange((start + count)..<(start + count * 2))
                    return result.joined(separator: " ")
                }
            }
        }
        // 形态二：无空白，紧邻重复的字符段（含数字才删、段长 ≥ 3，如“248弄”）。
        let chars = Array(text)
        if chars.count >= 6 {
            for length in (3...(chars.count / 2)).reversed() {
                for start in 0...(chars.count - length * 2) {
                    let first = chars[start..<(start + length)]
                    let second = chars[(start + length)..<(start + length * 2)]
                    guard first.elementsEqual(second) else { continue }
                    let segment = String(first)
                    guard segment.rangeOfCharacter(from: .decimalDigits) != nil else { continue }
                    var result = chars
                    result.removeSubrange((start + length)..<(start + length * 2))
                    return String(result)
                }
            }
        }
        return text
    }
}

/// 按当前系统语言重取地名（2026-11-14 Li 定，推翻方案 A“只存地点文字、不存经纬度”口径）：
/// 日记地点改存经纬度；显示层按当前语言逆地理编码取地名，切语言后地名跟着变；
/// 逆地理编码失败／离线时回退显示原存地名（调用方保留同步算出的原存文本行）；
/// 无经纬度的旧日记不解析，只显示原存地名。
/// 地名派生与写路径同口径（placemark.name + district(from:)），只差语言是当前的；
/// 可见性脱敏与同步 display 完全一致（公开→精度封顶后的地域文本、私密→精度封顶、他人→地域文本）。
enum BearyLocationDisplayNames {
    /// 坐标＋语言 → 解析出的（精确名，区级，国家，省/州，城市，街道）。只活在内存里，随进程销毁；
    /// 切语言后键里的语言变了，旧缓存自然不再命中。失败不缓存，下次渲染再试。
    private static var cache: [String: (name: String?, district: String?, country: String?, region: String?, city: String?, street: String?)] = [:]
    /// 在途解析的回调表：同坐标同语言只发一次请求，多处共用回包。
    private static var pending: [String: [((name: String?, district: String?, country: String?, region: String?, city: String?, street: String?)?) -> Void]] = [:]

    private static func cacheKey(latitude: Double, longitude: Double) -> String {
        let lang = Locale.preferredLanguages.first ?? Locale.current.identifier
        return "\(latitude),\(longitude)|\(lang)"
    }

    /// 当前语言的地名（精确名，区级，国家，省/州，城市，街道）：有经纬度时逆地理编码取当语言地名；
    /// 失败／无经纬度／解析出空地名时回 nil，调用方保留原存文本。
    /// 回调总在主线程、总异步投递（缓存命中也不例外，调用方在 cellForRow 内调也安全）；
    /// 同一行重复渲染共用一次在途请求。调用方须在主线程调用。
    static func resolvedNames(for entry: Entry, completion: @escaping ((name: String?, district: String?, country: String?, region: String?, city: String?, street: String?)?) -> Void) {
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
                // 精度分级字段随同一份 placemark 一起取（显示层按精度封顶时用，
                // 缺字段向粗回退；与发布时存库的四字段同口径）。
                let resolved = DiaryLocation(name: name, district: district, latitude: lat, longitude: lng,
                                             country: placemark.country, region: placemark.administrativeArea,
                                             city: placemark.locality, street: placemark.thoroughfare)
                guard !resolved.isEmpty else {
                    callbacks.forEach { $0(nil) }
                    return
                }
                let names = (name, district, placemark.country, placemark.administrativeArea, placemark.locality, placemark.thoroughfare)
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
                location: DiaryLocation(name: names.name, district: names.district, latitude: entry.locationLatitude, longitude: entry.locationLongitude,
                                        country: names.country, region: names.region, city: names.city, street: names.street),
                isPublic: BearyEphemeral.isEffectivelyPublic(entry),
                viewerIsAuthor: BearyLocationDisplay.viewerIsAuthor(entry: entry))
            completion(line)
        }
    }

    /// 同步取缓存的地名行：当前语言的解析缓存已命中时直接返回按显示口径算出的行文
    /// （脱敏与 displayLine 完全一致）；未命中返回 nil，调用方走原存文本＋异步回包。
    /// 只读缓存，不触发解析；切语言后键里的语言变了，旧缓存自然不再命中。
    /// 调用方须在主线程调用。
    static func cachedDisplayLine(for entry: Entry) -> String? {
        guard let lat = entry.locationLatitude, let lng = entry.locationLongitude,
              (-90...90).contains(lat), (-180...180).contains(lng), (lat != 0 || lng != 0) else { return nil }
        guard let names = cache[cacheKey(latitude: lat, longitude: lng)] else { return nil }
        return BearyLocationDisplay.display(
            location: DiaryLocation(name: names.name, district: names.district, latitude: lat, longitude: lng,
                                    country: names.country, region: names.region, city: names.city, street: names.street),
            isPublic: BearyEphemeral.isEffectivelyPublic(entry),
            viewerIsAuthor: BearyLocationDisplay.viewerIsAuthor(entry: entry))
    }
}

/// 卡片与详情共用的底行（地址＋天气）渲染：位置行刷新与底行显隐。
/// 两处原先各写一套，流程逐字相同，只差标签／行视图标识符与异步回包的
/// id 守卫（卡片凭 cellEntryId，详情凭 entry.id）；抽成 helper 后标签与
/// 行视图作参数传入，id 守卫与弱引用各留调用方。
/// BearyLocationDisplay.display 与 BearyLocationDisplayNames 本已共享，不动。
enum BearyBottomRow {
    /// 底行（地址＋天气）显隐：地址与天气任一有内容即显，全无即整行隐藏、
    /// 不占位；无地址时地址组与间隔同藏，天气顶到左边缘。
    static func updateVisibility(locationLabel: UILabel, locationIconView: UIView, weatherSpacer: UIView, locationStack: UIView, weatherWrapLabel: UILabel, weatherNameLabel: UILabel, weatherTempLabel: UILabel) {
        let hasLocation = !(locationLabel.text ?? "").isEmpty
        let hasWeather = !weatherWrapLabel.isHidden || !weatherNameLabel.isHidden || !weatherTempLabel.isHidden
        locationIconView.isHidden = !hasLocation
        locationLabel.isHidden = !hasLocation
        weatherSpacer.isHidden = !hasLocation
        locationStack.isHidden = !hasLocation && !hasWeather
    }

    /// 位置行刷新（同步部分）：文案与脱敏全走 BearyLocationDisplay.display；
    /// display 返回 nil 时清文＋刷新显隐；缓存命中时首帧直接用解析后的行文，
    /// 不等异步回包，天气组首帧即在终位。返回 true 表示缓存未命中、调用方
    /// 仍需走 BearyLocationDisplayNames.displayLine 异步回包（回包应用见
    /// applyResolvedLine，id 守卫由调用方在闭包里先做）。
    @discardableResult
    static func refreshLocationRow(entry: Entry, locationLabel: UILabel, updateVisibility: () -> Void) -> Bool {
        guard let line = BearyLocationDisplay.display(entry: entry) else {
            locationLabel.text = nil
            updateVisibility()
            return false
        }
        locationLabel.text = line
        updateVisibility()
        // 跳动审计第 12 条：缓存命中时首帧直接用解析后的行文，不等异步回包，
        // 天气组首帧即在终位；缓存未命中才走异步回包。
        if let cached = BearyLocationDisplayNames.cachedDisplayLine(for: entry) {
            locationLabel.text = cached
            updateVisibility()
            return false
        }
        return true
    }

    /// 位置行异步回包应用：文案没变不碰布局；变了用 0.18s 局部过渡推天气组，
    /// 不瞬间横移（减动效／未进窗口时直设终值）。
    static func applyResolvedLine(_ resolved: String, locationLabel: UILabel, locationLineRow: UIView, updateVisibility: () -> Void) {
        guard resolved != locationLabel.text else { return }
        locationLabel.text = resolved
        updateVisibility()
        guard !UIAccessibility.isReduceMotionEnabled, locationLineRow.window != nil else { return }
        UIView.animate(withDuration: BearyMotion.localStateDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
            locationLineRow.layoutIfNeeded()
        })
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
