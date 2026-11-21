import XCTest

// ===== 多语言地基：String Catalog 完整性测试 =====
// 测试 target 无宿主 App，catalog 不在测试包内，故直接读仓库里的
// ios/App/App/Localizable.xcstrings JSON 断言（不走 bundle 查表）。
// 断言口径：
//  - sourceLanguage 为 zh-Hans（中文当原文）；
//  - 样板模块（BearyAppLock，13 条 key）的 zh 值与 key 一致、en 值存在、
//    非空、与中文不同；
//  - 含 %@ 占位符的 key，其中英文值占位符个数与中文一致（防翻译丢占位符，
//    丢了 String(format:) 会崩或错位）。
// 真机行为（切系统语言看英文）不在此测，由 Li 真机验，见 docs/i18n-plan.md。

final class BearyI18nCatalogTests: XCTestCase {

    /// 样板模块 BearyAppLock 的全部 key（与 BearyAppLock.swift 里的
    /// NSLocalizedString 调用一一对应；新增样板 key 时同步加到这里）。
    private static let sampleKeys = [
        "冷启动时验证一次；切到别的 App 再回来不重复。",
        "面容识别",
        "触控 ID",
        "生物识别",
        "设备未录入%@，请先在系统设置中录入",
        "此设备不支持生物识别",
        "设备未设置密码，请先在系统设置中设置密码",
        "此设备暂无法使用生物识别",
        "beary 已锁定",
        "使用%@解锁",
        "解锁",
        "使用%@解锁 beary",
        "验证未通过，请再试一次，也可用设备密码解锁",
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
        for key in Self.sampleKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "catalog 缺 key：\(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let zh = try XCTUnwrap(((localizations["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            let en = try XCTUnwrap(((localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            XCTAssertEqual(zh, key, "zh 值须与 key（中文原文）一致")
            XCTAssertFalse(en.isEmpty, "en 值为空：\(key)")
            XCTAssertNotEqual(en, key, "en 值与中文相同，未翻译：\(key)")
            XCTAssertEqual(
                en.components(separatedBy: "%@").count - 1,
                key.components(separatedBy: "%@").count - 1,
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
