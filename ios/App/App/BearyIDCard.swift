import Foundation

/// 注册后引导 ID 卡：本地数据与持久化。
///
/// 注意：只存本地，不写服务端。服务端 PUT /api/account/profile 对 display_name
/// 有唯一性校验（重名回 name_taken），且没有生日/城市字段——任务口径「服务端
/// display_name 无唯一性校验」与本地 worker.js 不符（见 PR 说明），故本流程
/// 不调任何 profile 接口；昵称可重复、空昵称回退默认名 Teddy。
struct BearyIDCardData: Codable {
    /// 解析后昵称（表单空着时填默认名 Teddy，永不为空）。
    var nickname: String
    /// 出生年份（2026-11-20 17:31 Li 追加：算年龄用；只有月日没有年份时年龄
    /// 算不出，等用户在编辑资料页补年份；老本地数据没有该字段，解码为 nil）。
    var birthdayYear: Int?
    var birthdayMonth: Int?
    var birthdayDay: Int?
    var country: String?
    var region: String?
    var city: String?

    /// 卡上生日：只月日，如「11月3日」；未填不显示。
    /// 2026-11-21 日期完全本地化：中文沿用既有插值，非中文走共享 helper。
    var birthdayText: String? {
        guard let month = birthdayMonth, let day = birthdayDay else { return nil }
        return BearyLocalizedDate.monthDayString(month: month, day: day)
    }

    /// 卡上城市：只城市名，不带国家/地区；未填不显示。
    var cityText: String? { city }

    /// 表单城市行：三级全选时「国家 · 地区 · 城市」，否则「请选择」。
    var cityFieldText: String {
        guard let country = country, let region = region, let city = city else { return "请选择" }
        return "\(country) · \(region) · \(city)"
    }

    var hasCity: Bool { country != nil && region != nil && city != nil }
}

enum BearyIDCardStore {

    // MARK: - Keys（均按用户分键：换号后新号仍应走一次本流程）

    private static func key(_ suffix: String, userId: Int?) -> String {
        "beary_post_registration_\(suffix)_\(userId ?? 0)"
    }

    /// 引导流程已走完（到过结束页并点「进入beary」，或中途被杀后由 pending 恢复走完）。
    static func isOnboardingSeen(userId: Int?) -> Bool {
        UserDefaults.standard.bool(forKey: key("onboarding_seen", userId: userId))
    }

    static func markOnboardingSeen(userId: Int?) {
        UserDefaults.standard.set(true, forKey: key("onboarding_seen", userId: userId))
        UserDefaults.standard.removeObject(forKey: key("onboarding_pending", userId: userId))
    }

    /// 新注册登录时立 pending；中途杀进程后下次冷启动凭它恢复引导（只弹一次的另一半）。
    static func isOnboardingPending(userId: Int?) -> Bool {
        UserDefaults.standard.bool(forKey: key("onboarding_pending", userId: userId))
    }

    static func markOnboardingPending(userId: Int?) {
        UserDefaults.standard.set(true, forKey: key("onboarding_pending", userId: userId))
    }

    static func clearOnboardingPending(userId: Int?) {
        UserDefaults.standard.removeObject(forKey: key("onboarding_pending", userId: userId))
    }

    /// ID 卡表单已弹过（生成/跳过/拖走关闭均记一次，只弹一次）。
    static func isFormSeen(userId: Int?) -> Bool {
        UserDefaults.standard.bool(forKey: key("idcard_form_seen", userId: userId))
    }

    static func markFormSeen(userId: Int?) {
        UserDefaults.standard.set(true, forKey: key("idcard_form_seen", userId: userId))
    }

    /// ID 卡待弹：生成/跳过后 380ms 窗口内有 modal 在前、或被杀时，凭它下次
    /// 冷启动补弹（卡数据已存，见 save/load）。卡片弹出后清掉。
    static func isCardPending(userId: Int?) -> Bool {
        UserDefaults.standard.bool(forKey: key("idcard_pending", userId: userId))
    }

    static func markCardPending(userId: Int?) {
        UserDefaults.standard.set(true, forKey: key("idcard_pending", userId: userId))
    }

    static func clearCardPending(userId: Int?) {
        UserDefaults.standard.removeObject(forKey: key("idcard_pending", userId: userId))
    }

    // MARK: - Card data

    static func save(_ data: BearyIDCardData, userId: Int?) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: key("idcard", userId: userId))
    }

    static func load(userId: Int?) -> BearyIDCardData? {
        guard let raw = UserDefaults.standard.data(forKey: key("idcard", userId: userId)) else { return nil }
        return try? JSONDecoder().decode(BearyIDCardData.self, from: raw)
    }

    // MARK: - Stats（真实数据；预览里的 1/1/1 是 mock）

    struct Stats {
        /// 加入天数：注册当天记 1。
        let joinDays: Int
        /// 写的日记篇数：本地已同步篇数；新号为 0。
        let diaryCount: Int
        /// 连续记录天数：App 内尚无 streak 来源，新号首日记 1。
        let streakDays: Int
        /// SINCE：注册日期「yyyy.M.d」，如 2026.11.17；createdAt 缺失时取今天。
        let sinceText: String
    }

    static func stats(userId: Int?, createdAtMs: Int?) -> Stats {
        let now = Date()
        let joinDays: Int
        let sinceDate: Date
        if let createdAtMs = createdAtMs, createdAtMs > 0 {
            let created = Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000)
            sinceDate = created
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: created), to: Calendar.current.startOfDay(for: now)).day ?? 0
            joinDays = max(1, days + 1)
        } else {
            sinceDate = now
            joinDays = 1
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.M.d"
        let diaryCount: Int
        if let userId = userId, userId != 0 {
            diaryCount = BearyEntrySyncStore.loadAllEntries(accountId: userId)?.count ?? 0
        } else {
            diaryCount = 0
        }
        return Stats(joinDays: joinDays, diaryCount: diaryCount, streakDays: 1, sinceText: formatter.string(from: sinceDate))
    }
}

// MARK: - ID card server sync（2026-11-20 Li 定：生日只月日、城市三级选，均服务端同步）

/// 生日/城市 PUT 回包（只取 echo 的字段；失败时不关心内容）。
/// decoder 用 convertFromSnakeCase（BearyAPI.shared），CodingKeys 只写
/// camelCase 名（显式 snake_case rawValue 与该策略叠加后恒为 nil，见
/// BearyUserProfile 同款教训）；单字字段直接映射。
private struct BearyIDCardUpdateResponse: Decodable {
    var ok: Bool?
    var birthdayYear: Int?
    var birthdayMonth: Int?
    var birthdayDay: Int?
    var country: String?
    var region: String?
    var city: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case birthdayYear
        case birthdayMonth
        case birthdayDay
        case country
        case region
        case city
    }
}

enum BearyIDCardSync {
    /// /me 成功后调一次，生日与城市各自独立，分两个方向：
    /// 下行——服务端有值 → 以服务端为准写回本地卡数据（只动生日/城市字段，昵称不动；
    /// 本地还没有卡数据时按服务端值新建一条，昵称取 display_name、缺省为 Teddy，
    /// 这样新手机登录后 ID 卡不经重填就能显示服务端的值）；
    /// 上行——服务端没有、本地有 → 上传一次做迁移（同值重发是幂等写，不怕重复）；
    /// 两边都没有 → 什么都不做。失败静默（下次 /me 再试），不阻塞登录流程。
    static func syncFromMe(_ me: MeUser, userId: Int?) {
        guard let userId = userId, userId != 0 else { return }
        let serverBirthday: (year: Int?, month: Int, day: Int)? = {
            guard let month = me.birthdayMonth, let day = me.birthdayDay else { return nil }
            return (me.birthdayYear, month, day)
        }()
        let serverCity: (country: String, region: String, city: String)? = {
            guard let country = me.country, let region = me.region, let city = me.city else { return nil }
            return (country, region, city)
        }()
        // 下行：服务端有值 → 写回本地（只改动有变化的字段；年份可能为空，
        // 老服务端数据只有月日时年份不动、不清空本地已有年份）。
        if serverBirthday != nil || serverCity != nil {
            if var local = BearyIDCardStore.load(userId: userId) {
                var changed = false
                if let birthday = serverBirthday, (local.birthdayMonth != birthday.month || local.birthdayDay != birthday.day || (birthday.year != nil && local.birthdayYear != birthday.year)) {
                    local.birthdayYear = birthday.year ?? local.birthdayYear
                    local.birthdayMonth = birthday.month
                    local.birthdayDay = birthday.day
                    changed = true
                }
                if let city = serverCity, (local.country != city.country || local.region != city.region || local.city != city.city) {
                    local.country = city.country
                    local.region = city.region
                    local.city = city.city
                    changed = true
                }
                if changed { BearyIDCardStore.save(local, userId: userId) }
            } else {
                let trimmed = me.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = (trimmed?.isEmpty == false) ? (trimmed ?? "Teddy") : "Teddy"
                BearyIDCardStore.save(BearyIDCardData(
                    nickname: resolved,
                    birthdayYear: serverBirthday?.year,
                    birthdayMonth: serverBirthday?.month,
                    birthdayDay: serverBirthday?.day,
                    country: serverCity?.country,
                    region: serverCity?.region,
                    city: serverCity?.city
                ), userId: userId)
            }
        }
        // 上行：服务端没有、本地有 → 上传迁移（年份有就带上，没有就只发月日，
        // 服务端年份留空，等用户在编辑资料页补）。
        let local = BearyIDCardStore.load(userId: userId)
        if serverBirthday == nil,
           let month = local?.birthdayMonth, let day = local?.birthdayDay {
            uploadBirthday(month: month, day: day, year: local?.birthdayYear)
        }
        if serverCity == nil,
           let country = local?.country, let region = local?.region, let city = local?.city {
            uploadCity(country: country, region: region, city: city)
        }
    }

    /// 只发生日三字段的 PUT（不带 display_name，不触发唯一性校验；年份
    /// 为空时不发该键，服务端年份不动）。
    static func uploadBirthday(month: Int, day: Int, year: Int? = nil) {
        var body: [String: Any] = ["birthday_month": month, "birthday_day": day]
        if let year = year { body["birthday_year"] = year }
        BearyAPI.shared.request("/api/account/profile", method: "PUT", jsonBody: body) { (result: Result<BearyIDCardUpdateResponse, APIError>) in
            // 失败静默：下次 /me 成功时再试；成功也不用再做什么（服务端已有）。
        }
    }

    /// 只发城市三字段的 PUT（不带 display_name，不触发唯一性校验）。
    static func uploadCity(country: String, region: String, city: String) {
        BearyAPI.shared.request("/api/account/profile", method: "PUT", jsonBody: ["country": country, "region": region, "city": city]) { (result: Result<BearyIDCardUpdateResponse, APIError>) in
            // 失败静默：下次 /me 成功时再试；成功也不用再做什么（服务端已有）。
        }
    }
}
