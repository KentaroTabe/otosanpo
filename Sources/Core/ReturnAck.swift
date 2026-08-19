import Foundation

/// 帰路に同意した直後の確認音(returnAck)を、いつまで繰り返すか。
///
/// この音の役目は**「同意が伝わったか」の不安を消すこと**だけ(docs/01・利用者要望)。
/// 導入した当時は同意の直後に他の音が無かったので、一定時間くり返していた。
///
/// **案内が始まれば、それ自体が「伝わった」ことの答えになる。**
/// 実測(2026-08-19)では、確認音が誘導とビーコンを 60 秒せき止めており、
/// **帰路の最初の 64 秒間、方向の手がかりが 1 つも鳴っていなかった**。
/// 「どちらへ向かえばいいか最も分からない場面で音が少ない」という指摘はこれ。
///
/// そこで「方向のある音が鳴り始めるまで」に短縮する。上限は残す —
/// 進行方向が取れない・地図が無いなど、案内を出せない状況では確認音だけが頼りになるため。
public enum ReturnAck {
    /// 確認音を鳴らし続けるか。
    /// - Parameters:
    ///   - directionStarted: 方向のある音(誘導・左右のついたビーコン)を鳴らせたか
    ///   - elapsedSec: 同意からの経過
    ///   - durationSec: 上限(`return_ack_duration_sec`)
    public static func shouldRepeat(directionStarted: Bool, elapsedSec: Double,
                                    durationSec: Double) -> Bool {
        !directionStarted && elapsedSec < durationSec
    }
}
