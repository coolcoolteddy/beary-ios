import Foundation
import StoreKit

// ===== Plus 内购（StoreKit 2，2026-11-25 Li 定现在做）=====
// 三件商品（App Store Connect 已建好、CREATED，随 1.0 重提一起交）：
// 包月 plus1mon ¥12、包年 plus1year ¥68、永久 plus_lifetime ¥198。
// 购买流程：系统支付 → 取 VerificationResult.jwsRepresentation →
// POST /api/account/plus-verify 服务端校验（验 JWS 签名＋发权益）→
// 校验通过才 finish 交易。校验失败／网络异常时不 finish，交易留在
// 未完成队列里，下次启动由 Transaction.updates 重投递再验，不丢单。
// 服务端验单实现见 ~/workspace/plus-iap-server-diff/（只备 diff，不部署）。
// 本文件只负责购买与验单接线，不动 BearyPlusGate 统一门的总闸
// （isOpenForAll=true 免费期行为不变），不碰其他 Plus 逻辑。
// 对外一律 completion-handler 口径（与 BearyAPI 同款），内部用 Task 桥接
// StoreKit 2 的 async 接口；回调一律回主线程。
// 注意：模拟器／未签名环境拉不到商品（products 为空），属 StoreKit 环境
// 限制不是 bug；真购买须真机＋沙盒账号验。

/// Plus 三档套餐（顺序即页面胶囊顺序：包月→包年→永久，默认包月）。
enum BearyPlusProduct: String, CaseIterable {
    case monthly
    case yearly
    case lifetime

    /// App Store Connect 商品 ID（与服务端白名单同值）。
    var productID: String {
        switch self {
        case .monthly: return "plus1mon"
        case .yearly: return "plus1year"
        case .lifetime: return "plus_lifetime"
        }
    }

    /// 套餐胶囊文案 key（v32 定版：英文胶囊 Monthly/Yearly/Lifetime，
    /// catalog 里中英文同值，见 Localizable.xcstrings）。
    var tierTitleKey: String {
        switch self {
        case .monthly: return "plus.tier.monthly"
        case .yearly: return "plus.tier.yearly"
        case .lifetime: return "plus.tier.lifetime"
        }
    }
}

/// 购买结果：成功带服务端验单回包；取消／待确认（家长审批等）单独分流，
/// 调用方须给明确反馈，不静默吞掉。
enum BearyPlusPurchaseResult {
    case success(BearyPlusVerifyResponse)
    case cancelled
    case pending
    case failure(BearyPlusStoreError)
}

enum BearyPlusStoreError: Error {
    /// 商品拉不到（StoreKit 环境／网络），可重试。
    case productsUnavailable
    /// 服务端验单拒绝（invalid_jws／bad_bundle／bad_product 等）。
    case verificationFailed
    /// 这笔购买已被 Apple 撤销（退款／撤单），不解锁。
    case revoked
    /// 未登录：验单接口 401。交易不 finish，登录后由 updates 监听补验。
    case notLoggedIn
    /// 网络／服务端 5xx：可重试，交易不 finish，稍后自动补验。
    case network(APIError)
    case unknown
}

final class BearyPlusStore {
    static let shared = BearyPlusStore()

    static var productIDs: [String] {
        BearyPlusProduct.allCases.map { $0.productID }
    }

    /// 拉到过的商品缓存（key：productID）；购买前未拉到会先拉一次。
    private var cachedProducts: [String: Product] = [:]
    private var isObservingTransactions = false

    private init() {}

    // MARK: - 商品

    /// 拉三件商品；失败或空结果都按 productsUnavailable 回（调用方 toast＋重试）。
    func loadProducts(completion: @escaping (Result<[Product], BearyPlusStoreError>) -> Void) {
        Task {
            do {
                let products = try await Product.products(for: Self.productIDs)
                let found = products.filter { Self.productIDs.contains($0.id) }
                guard !found.isEmpty else {
                    await MainActor.run { completion(.failure(.productsUnavailable)) }
                    return
                }
                let cache = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
                await MainActor.run {
                    self.cachedProducts = cache
                    completion(.success(found))
                }
            } catch {
                await MainActor.run { completion(.failure(.productsUnavailable)) }
            }
        }
    }

    func product(for plan: BearyPlusProduct) -> Product? {
        cachedProducts[plan.productID]
    }

    // MARK: - 购买

    /// 买一档套餐：系统支付 → 服务端验单 → 通过才 finish。
    /// 验单网络异常时重试一次，仍失败则不 finish（下次启动补验）。
    func purchase(_ product: Product, completion: @escaping (BearyPlusPurchaseResult) -> Void) {
        Task {
            do {
                let result = try await product.purchase()
                switch result {
                case .success(let verification):
                    await self.handleVerifiedPurchase(verification, completion: completion)
                case .userCancelled:
                    await MainActor.run { completion(.cancelled) }
                case .pending:
                    await MainActor.run { completion(.pending) }
                @unknown default:
                    await MainActor.run { completion(.failure(.unknown)) }
                }
            } catch {
                await MainActor.run { completion(.failure(.unknown)) }
            }
        }
    }

    private func handleVerifiedPurchase(
        _ verification: VerificationResult<Transaction>,
        completion: @escaping (BearyPlusPurchaseResult) -> Void
    ) async {
        // JWS 在外层 VerificationResult 上，不在 Transaction 上
        // （Transaction 只有未签名的 jsonRepresentation，绝不能送服务端）。
        let jws = verification.jwsRepresentation
        guard case .verified(let transaction) = verification else {
            await MainActor.run { completion(.failure(.verificationFailed)) }
            return
        }
        guard Self.productIDs.contains(transaction.productID) else {
            // 不是本 App 的三件商品：不动它（不 finish，留给归属方处理）。
            await MainActor.run { completion(.failure(.verificationFailed)) }
            return
        }
        // 已撤销的交易（退款／撤单）：finish 掉，不解锁。
        if transaction.revocationDate != nil {
            await transaction.finish()
            await MainActor.run { completion(.failure(.revoked)) }
            return
        }
        let outcome = await verify(jws: jws, retryOnce: true)
        switch outcome {
        case .granted(let response):
            // 先 finish 再刷新本地用户态：权益已落库，刷新失败也不影响开通。
            await transaction.finish()
            SessionManager.shared.refreshMe()
            await MainActor.run { completion(.success(response)) }
        case .revoked:
            await transaction.finish()
            await MainActor.run { completion(.failure(.revoked)) }
        case .rejected:
            await transaction.finish()
            await MainActor.run { completion(.failure(.verificationFailed)) }
        case .notLoggedIn:
            await MainActor.run { completion(.failure(.notLoggedIn)) }
        case .retryable(let apiError):
            // 网络／服务端 5xx：不 finish，留给下次启动的 updates 监听补验。
            await MainActor.run { completion(.failure(.network(apiError))) }
        }
    }

    // MARK: - 恢复购买（3.1.1：终身是非消耗品，须有恢复入口）

    /// AppStore.sync 后扫 currentEntitlements，逐笔验单；返回成功恢复的笔数。
    /// 已验过的交易服务端直接回当前状态（already_verified），不重复发权益。
    func restorePurchases(completion: @escaping (Result<Int, BearyPlusStoreError>) -> Void) {
        Task {
            do {
                try await AppStore.sync()
            } catch {
                await MainActor.run { completion(.failure(.unknown)) }
                return
            }
            var restored = 0
            for await result in Transaction.currentEntitlements {
                // JWS 在外层 VerificationResult 上（见 handleVerifiedPurchase 注释）。
                let jws = result.jwsRepresentation
                guard case .verified(let transaction) = result else { continue }
                guard Self.productIDs.contains(transaction.productID) else { continue }
                if transaction.revocationDate != nil {
                    await transaction.finish()
                    continue
                }
                switch await verify(jws: jws, retryOnce: false) {
                case .granted:
                    restored += 1
                    await transaction.finish()
                case .revoked, .rejected:
                    await transaction.finish()
                case .notLoggedIn, .retryable:
                    break
                }
            }
            let count = restored
            await MainActor.run { completion(.success(count)) }
            if count > 0 {
                SessionManager.shared.refreshMe()
            }
        }
    }

    // MARK: - 交易监听（冷启动挂一次，处理续订／中途崩溃的重投递）

    /// 在 SceneDelegate 冷启动时调一次；重复调用直接返回。
    /// 续订是新 transactionId、同 originalTransactionId，到这里正常验单顺延。
    func startObservingTransactions() {
        guard !isObservingTransactions else { return }
        isObservingTransactions = true
        Task {
            for await result in Transaction.updates {
                // JWS 在外层 VerificationResult 上（见 handleVerifiedPurchase 注释）。
                let jws = result.jwsRepresentation
                guard case .verified(let transaction) = result else { continue }
                guard Self.productIDs.contains(transaction.productID) else { continue }
                if transaction.revocationDate != nil {
                    await transaction.finish()
                    continue
                }
                switch await self.verify(jws: jws, retryOnce: false) {
                case .granted:
                    await transaction.finish()
                    SessionManager.shared.refreshMe()
                case .revoked, .rejected:
                    await transaction.finish()
                case .notLoggedIn, .retryable:
                    // 未登录／网络异常：不 finish，下次启动重投递再验。
                    break
                }
            }
        }
    }

    // MARK: - 服务端验单

    private enum VerifyOutcome {
        case granted(BearyPlusVerifyResponse)
        case revoked
        case rejected
        case notLoggedIn
        case retryable(APIError)
    }

    /// 调 POST /api/account/plus-verify（body {jws}）。
    /// 服务端 200 回 ok:false 时按 error 码分流：revoked／expired→revoked，
    /// 其余→rejected；401→notLoggedIn；网络／5xx→retryable（可重试一次）。
    private func verify(jws: String, retryOnce: Bool) async -> VerifyOutcome {
        let outcome = await verifyOnce(jws: jws)
        if retryOnce, case .retryable = outcome {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return await verifyOnce(jws: jws)
        }
        return outcome
    }

    private func verifyOnce(jws: String) async -> VerifyOutcome {
        await withCheckedContinuation { continuation in
            BearyAPI.shared.verifyPlusPurchase(jws: jws) { result in
                switch result {
                case .success(let response):
                    if response.ok {
                        continuation.resume(returning: .granted(response))
                    } else if response.error == "revoked" || response.error == "expired" {
                        continuation.resume(returning: .revoked)
                    } else {
                        continuation.resume(returning: .rejected)
                    }
                case .failure(let error):
                    switch error {
                    case .unauthorized, .authFailure:
                        continuation.resume(returning: .notLoggedIn)
                    case .network, .http(500...599, _), .server(_, .some(500...599)):
                        continuation.resume(returning: .retryable(error))
                    default:
                        continuation.resume(returning: .rejected)
                    }
                }
            }
        }
    }
}
