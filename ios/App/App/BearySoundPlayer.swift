import AVFoundation
import UIKit

// MARK: - 音效播放器（2026-10-29 音效包接入，Li 定用助理代码合成版）
// 音频文件：App/Sounds/*.wav（11 个，Bundle.main Resources 平铺，
// 与 Lottie json 同款入包口径）；播放口径与 BearyHaptics 三件套同款：
// 音效只叠加在震动之上、绝不替代震动；不拿减动效门控（减动效只管视觉，
// 震动与音效照常给）；唯一门控是设置页“音效”开关 + 系统静音键。

/// 音效名 = Bundle 内 wav 文件名（不含扩展名）。
enum BearySound: String {
    case fabPop = "fab_pop"
    case publishSuccess = "publish_success"
    case likePop = "like_pop"
    case unlikeSoft = "unlike_soft"
    case bookmarkTick = "bookmark_tick"
    case visibilityClick = "visibility_click"
    case emoteChirp = "emote_chirp"
    case deleteSwoosh = "delete_swoosh"
    case refuseBonk = "refuse_bonk"
    case loginChime = "login_chime"
    case wishDing = "wish_ding"
}

enum BearySoundPlayer {
    /// 设置页“音效”开关的 UserDefaults 键；默认开（无档位时读 true）。
    static let enabledDefaultsKey = "beary_sound_enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// 播放中实例持有：AVAudioPlayer 需强持有到播完，否则还没出声就被释放；
    /// 播完后按时长 + 0.1s 从播放列表移除并回池（见下方播放器池），
    /// 池满才丢弃，不长期无界增长。单音最长 0.4s，并发数极小。
    private static var activePlayers: [AVAudioPlayer] = []
    private static var sessionConfigured = false

    // MARK: - 播放器池（审计三轮第 25 项：原来 play 每次现建播放器）
    // 原问题：play 每次在调用线程（UI 操作即主线程）做 Bundle.main.url +
    // AVAudioPlayer(contentsOf:) + prepareToPlay，即每次播放都把文件 IO 与
    // 解码压在主线程关键路径上。改法：每音效一个小池复用 + 后台预热。
    // 不变项：音色、音量、触发点一律不变——同名文件、不改 volume/rate、
    // 调用 play 当即出声（命中池或冷启动兜底），绝不排队延迟播放；
    // 门控不变：设置页“音效”开关 + .ambient（跟随静音键）+ mixWithOthers。
    /// 每音效空闲池上限：点赞连点等同音并发 burst 通常 ≤2，超出走同步兜底
    /// 新建（罕见，与旧行为一致），播完回池时按上限丢弃多余。
    private static let maxPooledPerSound = 2
    /// 常用音效：点赞 / 发布 / FAB——首次播放时在后台预热，之后命中池。
    private static let prewarmSounds: [BearySound] = [.likePop, .publishSuccess, .fabPop]
    /// 空闲池：只在后台队列与主线程清理闭包之间共享，一律经 poolLock 访问。
    private static var pooledPlayers: [BearySound: [AVAudioPlayer]] = [:]
    private static var prewarmScheduled = false
    private static let poolLock = NSLock()
    /// 后台串行队列：文件 IO + 解码（Bundle.url / AVAudioPlayer(contentsOf:) /
    /// prepareToPlay）只在这里做，绝不上主线程；播放调用本身只做取池 + play()。
    private static let poolQueue = DispatchQueue(label: "com.beary.soundPool", qos: .utility)

    static func play(_ sound: BearySound) {
        guard isEnabled else { return }
        // 首次播放时顺带触发常用音效后台预热（只调度一次，本身极轻）。
        schedulePrewarmIfNeeded()
        do {
            try ensureAudioSession()
        } catch {
            // 音频播不出不影响业务：静默失败，不弹 toast、不记日志。
            return
        }
        // 命中池：零文件 IO、零解码，只有取池 + play()，调用保持轻。
        let player: AVAudioPlayer
        if let pooled = takePooledPlayer(for: sound) {
            player = pooled
            player.currentTime = 0
            // 已解码数据仍在内存，prepareToPlay 只是内存侧就绪，不读文件。
            player.prepareToPlay()
            refillPoolIfEmpty(for: sound)
        } else if let built = buildPlayer(for: sound) {
            // 冷启动兜底：该音效首次播放（或同音 burst 超出池上限/预热在途）
            // 时才同步新建，与旧行为一致；播完即回池，此后同音效走池。
            player = built
        } else {
            return
        }
        poolLock.lock()
        activePlayers.append(player)
        poolLock.unlock()
        player.play()
        let duration = player.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            poolLock.lock()
            activePlayers.removeAll { $0 === player }
            poolLock.unlock()
            returnPlayerToPool(player, for: sound)
        }
    }

    /// 音频会话：.ambient 跟随静音键（静音时不响），mixWithOthers 不打断
    /// 其他音频；App 内无其他音频会话，本配置只影响本播放器自己的播出。
    /// 只做会话配置，无文件 IO，留在调用线程与旧行为一致。
    private static func ensureAudioSession() throws {
        if !sessionConfigured {
            try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            sessionConfigured = true
        }
    }

    /// 建播放器：Bundle 寻址 + 解码准备。只允许在后台队列（预热/补池）
    /// 或冷启动兜底时调用；池命中路径绝不经过这里。
    private static func buildPlayer(for sound: BearySound) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else { return nil }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            return player
        } catch {
            // 音频播不出不影响业务：静默失败，不弹 toast、不记日志。
            return nil
        }
    }

    private static func takePooledPlayer(for sound: BearySound) -> AVAudioPlayer? {
        poolLock.lock()
        defer { poolLock.unlock() }
        guard var pool = pooledPlayers[sound], !pool.isEmpty else { return nil }
        let player = pool.removeLast()
        pooledPlayers[sound] = pool
        return player
    }

    private static func returnPlayerToPool(_ player: AVAudioPlayer, for sound: BearySound) {
        poolLock.lock()
        defer { poolLock.unlock() }
        guard (pooledPlayers[sound]?.count ?? 0) < maxPooledPerSound else { return }
        player.currentTime = 0
        pooledPlayers[sound, default: []].append(player)
    }

    /// 首次播放时调度一次：后台预热常用三音，每音 1 个备用。
    /// 正在播的那个播完也会回池，入池按上限丢弃多余，不会超池。
    private static func schedulePrewarmIfNeeded() {
        poolLock.lock()
        guard !prewarmScheduled else {
            poolLock.unlock()
            return
        }
        prewarmScheduled = true
        poolLock.unlock()
        poolQueue.async {
            for sound in prewarmSounds {
                poolLock.lock()
                let count = pooledPlayers[sound]?.count ?? 0
                poolLock.unlock()
                guard count < maxPooledPerSound else { continue }
                if let player = buildPlayer(for: sound) {
                    returnPlayerToPool(player, for: sound)
                }
            }
        }
    }

    /// 取走池里最后一个后，后台补 1 个备用，使下次播放仍命中池。
    private static func refillPoolIfEmpty(for sound: BearySound) {
        poolLock.lock()
        let isEmpty = pooledPlayers[sound]?.isEmpty ?? true
        poolLock.unlock()
        guard isEmpty else { return }
        poolQueue.async {
            if let player = buildPlayer(for: sound) {
                returnPlayerToPool(player, for: sound)
            }
        }
    }
}
