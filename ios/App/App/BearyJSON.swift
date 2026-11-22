import Foundation

/// snake_case JSON 编解码共享入口：落盘 JSON 与服务端字段口径只剩一处说了算。
///
/// 此前 BearyEntrySyncStore／BearyTrashSyncStore／BearyOfflineSaveStore 各自手写
/// makeEncoder／makeDecoder 工厂（逐字相同），BearyAPI init 里另有一份 inline 版，
/// 现全部改走这里。编码用 convertToSnakeCase、解码用 convertFromSnakeCase，
/// 与 BearyAPI 解码端配对，往返不丢字段。
///
/// 裸解码器／编码器各处不动——各有用途，PastSelf 等类型显式要求
/// 不用 snake_case 转换（见 BearyAPI.swift pastSelfDecoder 处注释），
/// 一刀切会改坏。
///
/// 本文件须同时编进 App 与 BearyCoreTests 两个 target：测试 target 不带宿主 App、
/// 不走 @testable，直接编文件；BearyNativeCommon.swift 不在测试 target 里，
/// 所以共享入口不能放那里（见 #938 教训）。
enum BearyJSON {
    /// snake_case 解码器（convertFromSnakeCase）。
    /// 配置后不再改动，共享实例可多处共用。
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// snake_case 编码器（convertToSnakeCase）。
    /// 配置后不再改动，共享实例可多处共用。
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}
