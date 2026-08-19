import Foundation

/// 歩ける道の種別。OSM の `highway` タグを、提案スコアに効く粒度まで畳んだもの。
/// 数値は保存形式に載るため、**既存の値を変えない**(増やすのは可)。
public enum WayClass: Int, Codable, Equatable, CaseIterable {
    /// 歩行者専用(footway / path / pedestrian / steps)
    case footway = 0
    /// 生活道路(residential / living_street / service)
    case residential = 1
    /// 幹線・準幹線(primary / secondary / tertiary)。横断コストが高い
    case arterial = 2

    /// 散歩として気持ちよい順の重み。スコアに掛ける係数ではなく、
    /// どの種別を好むかの序列(実際の係数は parameters.json 側)
    public var preferenceRank: Int {
        switch self {
        case .footway: 0
        case .residential: 1
        case .arterial: 2
        }
    }
}

/// 端末に置く経路データ。OSM から**必要な属性だけに削ぎ落とした**もの。
///
/// 落とすもの: 名前・住所・建物・POI。サイズが縮むだけでなく、
/// 余計な情報を端末に置かないため(docs/04 プライバシー)。
///
/// 保存形式は JSON。デバッグと再生ツールから直接読めることを優先した。
/// 生成は PC 側の `scripts/build_map.sh`(osmium + MapBuild)。
public struct WalkMap: Codable, Equatable, Sendable {
    public struct Way: Codable, Equatable {
        /// `nodes` への添字列。2 点未満の way は生成側で捨てる
        public var n: [Int]
        /// 道の種別
        public var cls: WayClass
        /// 横断コストの階級(0 = 横断ではない / 大きいほど渡るのが負担)。
        /// 幅員・信号の有無から生成側で決める
        public var cross: Int

        public init(n: [Int], cls: WayClass, cross: Int) {
            self.n = n
            self.cls = cls
            self.cross = cross
        }

        enum CodingKeys: String, CodingKey {
            case n
            case cls = "class"
            case cross
        }
    }

    /// 切り出しの中心と半径。自宅がこの円の外なら、この地図は使えない
    public var center: GeoPoint
    public var radiusM: Double
    /// 生成日(ISO 8601 の日付)。地図の鮮度を画面に出すために持つ
    public var generated: String
    /// [緯度, 経度] の並び。添字が節点番号
    public var nodes: [[Double]]
    public var ways: [Way]

    public init(center: GeoPoint, radiusM: Double, generated: String,
                nodes: [[Double]], ways: [Way]) {
        self.center = center
        self.radiusM = radiusM
        self.generated = generated
        self.nodes = nodes
        self.ways = ways
    }

    enum CodingKeys: String, CodingKey {
        case center
        case radiusM = "radius_m"
        case generated
        case nodes
        case ways
    }

    public func point(_ index: Int) -> GeoPoint? {
        guard nodes.indices.contains(index), nodes[index].count >= 2 else { return nil }
        return GeoPoint(latitude: nodes[index][0], longitude: nodes[index][1])
    }

    /// 与えた地点がこの地図の圏内か。圏外ならグリッドのみで動作する
    public func covers(_ p: GeoPoint) -> Bool {
        Geo.distanceM(center, p) <= radiusM
    }
}
