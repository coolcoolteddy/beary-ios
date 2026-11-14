import AVFoundation
import UIKit

// MARK: - 音效播放器（2026-10-29 音效包接入，Li 定用助理代码合成版）
// 音频文件：App/Sounds/*.wav（11 个，Bundle.main Resources 平铺，
// 与 Lottie json 同款入包口径）；播放口径与 BearyHaptics 三件套同款：
// 音效只叠加在震动之上、绝不替代震动；不拿减动效门控（减动效只管视觉，
// 震动与音效照常给）；唯一门控是设置页“音效”开关 + 系统静音键。

/// 音效名 = Bundle 内 wav 文件名（不含扩展名）。
enum BearySound: String, CaseIterable {
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
    /// 打断监听是否已注册（随 ensureAudioSession 首次配置注册一次；静态持有 token 防注销）。
    private static var interruptionObserver: NSObjectProtocol?

    // MARK: - 播放器池（审计三轮第 25 项：原来 play 每次现建播放器）
    // 原问题：play 每次在调用线程（UI 操作即主线程）做 Bundle.main.url +
    // AVAudioPlayer(contentsOf:) + prepareToPlay，即每次播放都把文件 IO 与
    // 解码压在主线程关键路径上。改法：每音效一个小池复用 + 后台预热。
    // 不变项：音色、音量、触发点一律不变——同名文件、不改 volume/rate；
    // 命中池当即出声；未命中不再主线程同步建播放器，改后台建好后
    // 回主线程播放，过期（见 play）则不播、只回池，绝不排队延迟播放；
    // 门控不变：设置页“音效”开关 + .ambient（跟随静音键）+ mixWithOthers。
    /// 每音效空闲池上限：点赞连点等同音并发 burst 通常 ≤2，超出走后台建
    /// 播放器、就绪后符合新鲜度才播放（见 play 未命中路径），播完回池
    /// 时按上限丢弃多余。
    private static let maxPooledPerSound = 2
    /// 审计动效组：全部 11 音在启动或闲时预热解码（旧口径只预热 3 音，
    /// 其余 9 音首次播放走主线程文件 IO）；预热只做后台解码，不改音色、
    /// 音量与触发点，门控仍是设置页开关 + .ambient + mixWithOthers。
    private static let prewarmSounds: [BearySound] = BearySound.allCases
    /// 空闲池：只在后台队列与主线程清理闭包之间共享，一律经 poolLock 访问。
    private static var pooledPlayers: [BearySound: [AVAudioPlayer]] = [:]
    /// 同音上次播放时刻（0.1s 节流用，只经 poolLock 访问；单调时钟 systemUptime，
    /// 不受系统时间回拨影响）。
    private static var lastPlayAt: [BearySound: TimeInterval] = [:]
    private static var prewarmScheduled = false
    private static let poolLock = NSLock()
    /// 后台串行队列：文件 IO + 解码（Bundle.url / AVAudioPlayer(contentsOf:) /
    /// prepareToPlay）只在这里做，绝不上主线程；播放调用本身只做取池 + play()。
    private static let poolQueue = DispatchQueue(label: "com.beary.soundPool", qos: .utility)

    /// 审计动效组：启动时调用（见 AppDelegate），后台解码全部 11 音；
    /// 与 play 内的 schedulePrewarmIfNeeded 共用一次门控，重复调用无额外开销。
    /// 第三轮审计 14：音效关闭时不排预热（门控在这里，任何调用点都安全）；
    /// 用户重新开启音效时由开关回调再调一次（一次门控尚未消耗，仍可调度）。
    static func prewarmAll() {
        guard isEnabled else { return }
        schedulePrewarmIfNeeded()
    }

    static func play(_ sound: BearySound) {
        guard isEnabled else { return }
        // 审计动效组：后台/锁屏不播音效（此前无此守卫；前台用户操作触发时恒为 active）。
        guard UIApplication.shared.applicationState == .active else { return }
        // 审计动效组：高频短音 0.1s 节流——同音 0.1s 内重复触发直接丢弃
        // （震动不节流；池复用仍负责同音 burst 的播放器复用）。
        poolLock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastPlayAt[sound], now - last < 0.1 {
            poolLock.unlock()
            return
        }
        lastPlayAt[sound] = now
        poolLock.unlock()
        // 首次播放时顺带触发全部音效后台预热（只调度一次，本身极轻）。
        schedulePrewarmIfNeeded()
        do {
            try ensureAudioSession()
        } catch {
            // 音频播不出不影响业务：静默失败，不弹 toast、不记日志。
            return
        }
        // 命中池：零文件 IO、零解码，只有取池 + play()，调用保持轻。
        guard let pooled = takePooledPlayer(for: sound) else {
            // 审计第 21 项残留缺口：未命中（预热未完成 / 同音 burst 超池）
            // 时不再主线程同步 buildPlayer——点按主线程只调度后台建播放器
            // 就立即返回；建好后回主线程、符合新鲜度才播放，过期不播只回池。
            scheduleMissedSoundBuild(sound, tappedAt: now)
            return
        }
        pooled.currentTime = 0
        // 已解码数据仍在内存，prepareToPlay 只是内存侧就绪，不读文件。
        pooled.prepareToPlay()
        refillPoolIfEmpty(for: sound)
        startPlaying(pooled, for: sound)
    }

    /// 主线程播放已就绪播放器：强持有到播完，播完回池（池满丢弃）。
    private static func startPlaying(_ player: AVAudioPlayer, for sound: BearySound) {
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

    /// 未命中路径：后台取播放器，建好后回主线程播放；过期交互音不排队延迟播放。
    /// 未命中任务排在整批预热后面：真正执行时预热可能已把该音放进池，
    /// 先重取池、池里有就直接用，不再重复建播放器；池仍空才建。
    /// 新鲜度三条（任一不满足即不播、播放器回池供下次命中）：
    /// 1) 仍在前台 active（与 play 入口守卫一致，锁屏/后台不补播）；
    /// 2) 距点按 < 0.5s（正常后台建播放器远低于此值，阈值只截断磁盘卡顿等
    ///    病态延迟，避免用户已翻页/做下一步后旧音效才突然响起）；
    /// 3) 仍是该音效最近一次点按（其后若已有更新点按走池播出，本次旧请求
    ///    不再叠播，只回池）。
    /// 设置开关在建好后复核：关了就不播（回池无害，下次开时可命中）。
    private static func scheduleMissedSoundBuild(_ sound: BearySound, tappedAt: TimeInterval) {
        poolQueue.async {
            guard let player = takePooledPlayer(for: sound) ?? buildPlayer(for: sound) else { return }
            DispatchQueue.main.async {
                let isFresh: Bool = {
                    guard isEnabled else { return false }
                    guard UIApplication.shared.applicationState == .active else { return false }
                    guard ProcessInfo.processInfo.systemUptime - tappedAt < 0.5 else { return false }
                    poolLock.lock()
                    let latest = lastPlayAt[sound]
                    poolLock.unlock()
                    return latest == tappedAt
                }()
                guard isFresh else {
                    returnPlayerToPool(player, for: sound)
                    return
                }
                do {
                    try ensureAudioSession()
                } catch {
                    returnPlayerToPool(player, for: sound)
                    return
                }
                startPlaying(player, for: sound)
            }
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
            observeInterruptionIfNeeded()
        }
    }

    /// 32 清单第 26 项：监听音频打断结束，打断结束即将会话复位（重设 .ambient +
    /// mixWithOthers 并 setActive），使打断后下一次音效不再静默。注册一次、常驻；
    /// 复位失败静默（不弹 toast、不记日志，与本文件失败口径一致）。
    /// 注意：.ambient + mixWithOthers 下系统可能已自动恢复会话，本改动届时为空操作——
    /// 属 Li 拍板接受的可能无用功，仅作防御。
    private static func observeInterruptionIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                // 下一次 play 经 ensureAudioSession 的 sessionConfigured 门控不再重设；
                // 为避免一次复位失败即永久静默，失败时把门控打回未配置，下次播放重走配置。
                sessionConfigured = false
            }
        }
    }

    /// 建播放器：Bundle 寻址 + 解码准备。只允许在后台队列（预热/补池/
    /// 未命中后台建）调用；点按主线程与池命中路径绝不经过这里。
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
            // 预热先配会话：buildPlayer 的 prepareToPlay 可能先激活默认会话、
            // 打断其他 App 的音频；先走 ensureAudioSession（.ambient +
            // mixWithOthers，sessionConfigured 防重复配置），配不上就不预热，
            // 与播放路径静默失败口径一致。只改顺序，不改会话参数。
            do {
                try ensureAudioSession()
            } catch {
                return
            }
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
