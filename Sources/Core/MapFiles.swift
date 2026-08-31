import Foundation

/// Documents に置かれた経路データを、**どの順に読むか**を決める。
///
/// ## なぜ要るか(2026-08-30)
///
/// 読むファイル名を `otosanpo-map.json` に固定していたため、
/// `scripts/build_maps.sh` が出す**都市名のファイル**(`名古屋市.json` など)を
/// そのまま置いたテスターの端末で**永久に読まれなかった**。
/// 手順書は改名を前提に書いていたが、配る側の道具は都市名で出していて、
/// 経路が繋がっていなかった。画面には理由の分からない「地図: 未読込」だけが出た。
///
/// **名前を問わず読む。** 置き場(Documents)と拡張子(`.json`)だけを条件にする。
/// こうすると、配った地図をそのまま保存するだけで読めるようになる。
public enum MapFiles {

    /// 以前から使っている名前。**互換のため最優先で読む。**
    /// すでに正しく置けている端末で、他のファイルを先に解こうとして遅くしないため
    public static let preferredName = "otosanpo-map.json"

    /// 読める見込みのあるファイル 1 つぶん。判定に要る情報だけを持つ
    public struct Candidate: Equatable {
        public let name: String
        public let modified: Date
        public let sizeBytes: Int

        public init(name: String, modified: Date, sizeBytes: Int) {
            self.name = name
            self.modified = modified
            self.sizeBytes = sizeBytes
        }
    }

    /// 読めなかった理由。**「未読込」の一言に潰さない。**
    /// 潰すと、名前違い・壊れている・大きすぎて読めない、が区別できなくなる
    public enum Failure: Equatable {
        /// `.json` が 1 つも置かれていない(まだ入れていない)
        case noFile
        /// 置かれてはいるが、経路データとして解けなかった(ファイル名を添える)
        case undecodable([String])
    }

    /// 読む順を決める。**正式名が先、その後は新しい順。**
    ///
    /// 先頭から試して**最初に解けたものを使う**。普通は 1 つしか置かれないので、
    /// 解く処理は 1 回で済む(20 km の地図は数十 MB あり、総当たりは重い)。
    ///
    /// 新しい順にするのは、地図を配り直したときに**新しいほうが勝つ**ため。
    /// 古いファイルを消し忘れても、意図した地図が使われる。
    public static func order(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { a, b in
            let aPreferred = a.name == preferredName
            let bPreferred = b.name == preferredName
            if aPreferred != bPreferred { return aPreferred }
            if a.modified != b.modified { return a.modified > b.modified }
            // 同着は名前で決める。**実行のたびに順が変わらないようにする**
            return a.name < b.name
        }
    }

    /// 置かれたファイルの指紋。**変わっていなければ読み直さない**ための印。
    ///
    /// 前面に戻るたびに数十 MB を解き直すと画面が固まるので、
    /// 「ファイルが入れ替わった時だけ読む」の判定に使う。
    /// 名前・更新時刻・サイズを見る(同じ秒に同名で差し替えられてもサイズで気づく)。
    public static func fingerprint(_ candidates: [Candidate]) -> String {
        order(candidates)
            .map { "\($0.name):\(Int($0.modified.timeIntervalSince1970)):\($0.sizeBytes)" }
            .joined(separator: "|")
    }
}
