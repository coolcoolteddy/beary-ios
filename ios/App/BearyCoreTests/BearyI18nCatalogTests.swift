import XCTest

// ===== 多语言地基：String Catalog 完整性测试 =====
// 测试 target 无宿主 App，catalog 不在测试包内，故直接读仓库里的
// ios/App/App/Localizable.xcstrings JSON 断言（不走 bundle 查表）。
// 断言口径：
//  - sourceLanguage 为 zh-Hans（中文当原文）；
//  - 样板模块（BearyAppLock，13 条 key）的 zh 值为中文原文（与期望值表
//    一致）、en 值存在、非空、与中文不同；
//  - 含 %@ 占位符的 key，其中英文值占位符个数与中文一致（防翻译丢占位符，
//    丢了 String(format:) 会崩或错位）。
// key 是语义 key（如 app_lock.unlock），中文只作 source value；改中文文案
// 只改 zh 值、不改 key——key 一旦合入不再改名，改名即丢翻译。
// 真机行为（切系统语言看英文）不在此测，由 Li 真机验，见 docs/i18n-plan.md。

final class BearyI18nCatalogTests: XCTestCase {

    /// 样板模块 BearyAppLock 的全部 key → 中文原文期望值
    /// （与 BearyAppLock.swift 里的 NSLocalizedString 调用一一对应；
    /// 新增样板 key 时同步加到这里；中文文案改了只改这里的期望值，不改 key）。
    private static let sampleKeys: [String: String] = [
        "app_lock.cold_start_note": "打开 App 时验证一次；切到别的 App 再回来不重复。",
        "app_lock.face_id": "面容识别",
        "app_lock.touch_id": "触控 ID",
        "app_lock.biometrics": "生物识别",
        "app_lock.biometry_not_enrolled": "设备未录入%@，请先在系统设置中录入",
        "app_lock.biometry_not_available": "此设备不支持生物识别",
        "app_lock.passcode_not_set": "设备未设置密码，请先在系统设置中设置密码",
        "app_lock.biometry_unavailable": "此设备暂无法使用生物识别",
        "app_lock.locked": "Beary 已锁定",
        "app_lock.unlock_with_biometry": "使用%@解锁",
        "app_lock.unlock": "解锁",
        "app_lock.unlock_beary_with_biometry": "使用%@解锁 Beary",
        "app_lock.verification_failed": "验证未通过，请再试一次，也可用设备密码解锁",
    ]

    private func catalogJSON() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #file)
        let catalogURL = testFile
            .deletingLastPathComponent() // BearyI18nCatalogTests.swift
            .deletingLastPathComponent() // BearyCoreTests/ -> ios/App/
            .appendingPathComponent("App")
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json)
    }

    func testCatalogSourceLanguageIsChinese() throws {
        let json = try catalogJSON()
        XCTAssertEqual(json["sourceLanguage"] as? String, "zh-Hans")
        XCTAssertEqual(json["version"] as? String, "1.0")
    }

    func testSampleKeysHaveChineseAndEnglish() throws {
        let json = try catalogJSON()
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        for (key, zhExpected) in Self.sampleKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "catalog 缺 key：\(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let zh = try XCTUnwrap(((localizations["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            let en = try XCTUnwrap(((localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            XCTAssertEqual(zh, zhExpected, "zh 值与期望的中文原文不一致：\(key)")
            XCTAssertFalse(en.isEmpty, "en 值为空：\(key)")
            XCTAssertNotEqual(en, zh, "en 值与中文相同，未翻译：\(key)")
            XCTAssertEqual(
                en.components(separatedBy: "%@").count - 1,
                zh.components(separatedBy: "%@").count - 1,
                "en 占位符 %@ 个数与中文不一致：\(key)"
            )
        }
    }

    func testCatalogHasNoEmptyEnglishValue() throws {
        let json = try catalogJSON()
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(strings.count, Self.sampleKeys.count)
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let enUnit = (localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any],
                  let en = enUnit["value"] as? String else {
                XCTFail("缺 en 翻译：\(key)")
                continue
            }
            XCTAssertFalse(en.isEmpty, "en 值为空：\(key)")
        }
    }
}
