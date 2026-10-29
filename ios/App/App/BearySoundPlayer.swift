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
    /// 播完后按时长 + 0.1s 清理，不长期占内存。单音最长 0.4s，并发数极小。
    private static var activePlayers: [AVAudioPlayer] = []
    private static var sessionConfigured = false

    static func play(_ sound: BearySound) {
        guard isEnabled else { return }
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else { return }
        do {
            if !sessionConfigured {
                // .ambient：跟随静音键（静音时不响），mixWithOthers 不打断其他音频；
                // App 内无其他音频会话，本配置只影响本播放器自己的播出。
                try AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
                try AVAudioSession.sharedInstance().setActive(true)
                sessionConfigured = true
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            activePlayers.append(player)
            player.play()
            let duration = player.duration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
                activePlayers.removeAll { $0 === player }
            }
        } catch {
            // 音频播不出不影响业务：静默失败，不弹 toast、不记日志。
            return
        }
    }
}
