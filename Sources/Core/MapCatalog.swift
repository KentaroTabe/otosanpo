import Foundation

/// 配信されている経路データの一覧。
///
/// **なぜ要るか**: テスターに経路データを手で渡すのが続かなかった。
/// iOS はファイルアプリ、Android は `Android/data/` へ置く必要があり、
/// **Android のテスターは実際に置けなかった**(2026-08-28。→ docs/10)。
///
/// **位置は送らない。** 送るのは利用者が自分で選んだ都市のファイル名だけ。
/// 「歩いた経路・自宅・ログは端末から出ない」は維持される(→ docs/12)。
///
/// 一覧は `scripts/build_map_catalog.sh` が `maps/set/` から作り、
/// 人が配信先へ上げる(外向きの操作は人が行う方針)。
public struct MapCatalog: Codable, Equatable, Sendable {
    /// 1 都市ぶん
    public struct Entry: Codable, Equatable, Sendable {
        /// 都市名。**ファイル名と同じ**にしておく(対応表を持たないため)
        public var name: String
        /// 配信先での相対パス
        public var file: String
        /// バイト数。落とす前に大きさを見せるために持つ
        public var bytes: Int
        /// この地図が覆う半径 [m]
        public var radiusM: Double
        public var center: GeoPoint
        /// 生成日(`YYYY-MM-DD`)。古さを見せるために持つ
        public var generated: String

        public init(name: String, file: String, bytes: Int,
                    radiusM: Double, center: GeoPoint, generated: String) {
            self.name = name
            self.file = file
            self.bytes = bytes
            self.radiusM = radiusM
            self.center = center
            self.generated = generated
        }

        enum CodingKeys: String, CodingKey {
            case name, file, bytes, center, generated
            case radiusM = "radius_m"
        }
    }

    public var generated: String
    public var cities: [Entry]

    public init(generated: String, cities: [Entry]) {
        self.generated = generated
        self.cities = cities
    }

    /// その地図が指定の点を覆うか。
    /// **覆う地図が 1 つも無い場合がある**(圏外の地域)ので、呼び出し側は空を扱えること
    public static func covers(_ e: Entry, _ p: GeoPoint) -> Bool {
        Geo.distanceM(e.center, p) <= e.radiusM
    }

    /// 現在地に近い順。**位置が取れなければ元の順のまま**(人口順で作っている)。
    ///
    /// 並べ替えは端末の中だけで行う。位置を配信先へ送らないため、
    /// 「近い順に出す」はこちらで計算するしかない
    public static func sorted(_ entries: [Entry], near p: GeoPoint?) -> [Entry] {
        guard let p else { return entries }
        return entries.sorted { a, b in
            Geo.distanceM(a.center, p) < Geo.distanceM(b.center, p)
        }
    }

    /// 現在地を覆う地図のうち、中心が最も近いもの。無ければ nil
    public static func best(_ entries: [Entry], for p: GeoPoint) -> Entry? {
        sorted(entries.filter { covers($0, p) }, near: p).first
    }
}
