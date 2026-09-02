import Foundation

/// 経路データのタイル分割(→ docs/12)。
///
/// **なぜタイルか**: 20 km 円の都市ファイルは「手で 1 ファイル渡す」前提の分割だった。
/// アプリが自分で取りに行けるなら、**必要な範囲(散歩の 5 km 圏)だけ**を取ればよい。
/// 40 MB の都市ファイルが 2 MB 前後の取得で済み、都市の円から漏れる地域も無くなる
/// (円方式では茨城県が丸ごと落ちていた・docs/04)。
///
/// **分割は緯度経度の等分割**。投影は使わない(散歩スケールでは過剰)。
/// タイル番号 = floor(緯度 / 角) と floor(経度 / 角) の整数対。
/// 1 タイルは 1 つの `WalkMap` として書かれ、既存の読み込みがそのまま使える。
///
/// **way は重心が属するタイルにだけ入る**(重複を作らないため)。
/// 縁で隣のタイルへはみ出す道は、隣のタイルを一緒に取れば揃う。
/// 取得圏の最外周だけが欠けうるが、これは円方式の「円外で除外」と同じ性質。
public enum MapTiles {

    /// タイル番号。ファイル名と 1 対 1
    public struct TileID: Hashable, Equatable, Sendable {
        public var y: Int
        public var x: Int

        public init(y: Int, x: Int) {
            self.y = y
            self.x = x
        }
    }

    /// 点が属するタイル
    public static func id(of p: GeoPoint, sizeDeg: Double) -> TileID {
        TileID(y: Int(floor(p.latitude / sizeDeg)), x: Int(floor(p.longitude / sizeDeg)))
    }

    /// 配信先・端末双方でのファイル名。**この名前が通信に載る**(位置の粒度はタイル角)
    public static func fileName(_ id: TileID) -> String {
        "t\(id.y)_\(id.x).json"
    }

    /// `fileName` の逆。タイル以外のファイルは nil
    public static func id(fromFileName name: String) -> TileID? {
        guard name.hasPrefix("t"), name.hasSuffix(".json") else { return nil }
        let body = name.dropFirst().dropLast(5)
        let parts = body.split(separator: "_")
        guard parts.count == 2, let y = Int(parts[0]), let x = Int(parts[1]) else { return nil }
        return TileID(y: y, x: x)
    }

    /// タイルの矩形の中心
    public static func center(of id: TileID, sizeDeg: Double) -> GeoPoint {
        GeoPoint(latitude: (Double(id.y) + 0.5) * sizeDeg,
                 longitude: (Double(id.x) + 0.5) * sizeDeg)
    }

    /// 点がタイルの矩形の中か
    public static func contains(_ id: TileID, _ p: GeoPoint, sizeDeg: Double) -> Bool {
        self.id(of: p, sizeDeg: sizeDeg) == id
    }

    /// いずれかのタイルの矩形の中か。
    /// **結合した地図の外接円で判定してはいけない** — 離れた 2 都市を取った利用者では
    /// 外接円が間の空白まで覆ってしまう。矩形の集合で厳密に見る
    public static func cover(_ ids: some Collection<TileID>, _ p: GeoPoint,
                             sizeDeg: Double) -> Bool {
        ids.contains(id(of: p, sizeDeg: sizeDeg))
    }

    /// 中心の周囲 radiusM の円と交わるタイルの一覧(y, x の昇順)。
    /// 判定は「矩形内で円中心に最も近い点までの距離」。矩形と円の標準の交差判定
    public static func covering(center c: GeoPoint, radiusM: Double,
                                sizeDeg: Double) -> [TileID] {
        let dLat = radiusM / Geo.metersPerDegreeLat
        let dLon = radiusM / (Geo.metersPerDegreeLat * cos(c.latitude * .pi / 180))
        let lo = id(of: GeoPoint(latitude: c.latitude - dLat, longitude: c.longitude - dLon),
                    sizeDeg: sizeDeg)
        let hi = id(of: GeoPoint(latitude: c.latitude + dLat, longitude: c.longitude + dLon),
                    sizeDeg: sizeDeg)
        var out: [TileID] = []
        for y in lo.y...hi.y {
            for x in lo.x...hi.x {
                let nearLat = min(max(c.latitude, Double(y) * sizeDeg), Double(y + 1) * sizeDeg)
                let nearLon = min(max(c.longitude, Double(x) * sizeDeg), Double(x + 1) * sizeDeg)
                let near = GeoPoint(latitude: nearLat, longitude: nearLon)
                if Geo.distanceM(c, near) <= radiusM {
                    out.append(TileID(y: y, x: x))
                }
            }
        }
        return out
    }

    /// 端末にあるタイルのうち、**基準点(自宅・現在地)の周りだけ**を選ぶ。
    ///
    /// なぜ要るか: 取得のたびにタイルは溜まる。全部を結合すると、旅行先で取った端末ほど
    /// 地図が肥大し、**散歩の開始時に作る経路の場が重くなる**
    /// (実測: 57 万節点で構築 5.1 秒・メモリ 241 MB。docs/04)。
    /// 歩くのに要るのは基準点の周り(散歩の 5 km 圏)だけなので、そこに絞る。
    public static func nearby(_ stored: [TileID], around points: [GeoPoint],
                              radiusM: Double, sizeDeg: Double) -> [TileID] {
        guard !points.isEmpty else { return stored }
        var wanted = Set<TileID>()
        for p in points {
            wanted.formUnion(covering(center: p, radiusM: radiusM, sizeDeg: sizeDeg))
        }
        return stored.filter { wanted.contains($0) }
    }

    /// 取りに行くタイル = 必要な範囲 −(端末にあるもの)−(データ無しと分かっているもの)。
    ///
    /// `retryEmpty` は「データ無し」の記録を無視してもう一度試す。
    /// 自動取得(散歩開始時)は false — 海沿いの自宅で**毎回 404 を取りに行かない**ため。
    /// ボタンからの取得は true — 配信が後から増えた場合に人の操作で拾い直せるように
    public static func toFetch(covering: [TileID], stored: some Collection<TileID>,
                               empty: some Collection<TileID>, retryEmpty: Bool) -> [TileID] {
        let storedSet = Set(stored)
        let emptySet = retryEmpty ? Set<TileID>() : Set(empty)
        return covering.filter { !storedSet.contains($0) && !emptySet.contains($0) }
    }

    // MARK: - 結合

    /// 複数のタイルを 1 つの `WalkMap` に組む。
    ///
    /// **節点は座標(1e-7 = 約 1 cm)で畳む。** タイルをまたぐ道は、境目の節点が
    /// 両側のタイルに同じ座標で入っている。畳まなければ**境目でグラフが切れ**、
    /// 帰路の経路の場(自宅からのダイクストラ)がタイルの縁で止まる。
    /// 丸めの桁は生成側(MapBuild の `nodeNumber`)と同じにしてある。
    ///
    /// 中心と半径は全節点の外接から出す(画面表示用。圏内判定には `cover` を使う)
    public static func assemble(_ maps: [WalkMap]) -> WalkMap? {
        guard !maps.isEmpty else { return nil }

        var nodeIndex: [String: Int] = [:]
        var nodes: [[Double]] = []
        var ways: [WalkMap.Way] = []

        func number(lat: Double, lon: Double) -> Int {
            let key = String(format: "%.7f,%.7f", lat, lon)
            if let i = nodeIndex[key] { return i }
            nodes.append([lat, lon])
            nodeIndex[key] = nodes.count - 1
            return nodes.count - 1
        }

        for map in maps {
            for way in map.ways {
                var indices: [Int] = []
                indices.reserveCapacity(way.n.count)
                for i in way.n {
                    guard map.nodes.indices.contains(i), map.nodes[i].count >= 2 else { continue }
                    indices.append(number(lat: map.nodes[i][0], lon: map.nodes[i][1]))
                }
                guard indices.count >= 2 else { continue }
                ways.append(WalkMap.Way(n: indices, cls: way.cls, cross: way.cross))
            }
        }
        guard !nodes.isEmpty else { return nil }

        var minLat = nodes[0][0], maxLat = nodes[0][0]
        var minLon = nodes[0][1], maxLon = nodes[0][1]
        for n in nodes {
            minLat = min(minLat, n[0]); maxLat = max(maxLat, n[0])
            minLon = min(minLon, n[1]); maxLon = max(maxLon, n[1])
        }
        let center = GeoPoint(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let corner = GeoPoint(latitude: maxLat, longitude: maxLon)
        let generated = maps.map(\.generated).max() ?? ""
        return WalkMap(center: center, radiusM: Geo.distanceM(center, corner),
                       generated: generated, nodes: nodes, ways: ways)
    }
}

/// どの地図で歩くか。**手で入れた地図とタイルは競合させない**(→ docs/12)。
///
/// 前提: 手で入れた地図(`otosanpo-map.json`)を配っていた時期がある。
/// タイルの取得はそれを**上書きせず**、別の置き場(map-tiles/)に落とす。
/// 両方ある端末で、どちらを読むかをここで決める。
public enum MapSource: Equatable, Sendable {
    case manual
    case tiles
    case none

    /// 決め方(表は MapSourceTests に同じ形で固定してある):
    ///
    /// - **タイルが勝つのは「タイルは現在地を覆い、手動は覆わない」時だけ。**
    ///   引っ越し・旅行で古い都市ファイルが現在地から外れた場合がこれに当たる
    /// - それ以外で手動があれば手動。**人が意図して置いたものを黙って差し替えない**し、
    ///   既存テスターの挙動が変わらない
    /// - 位置が取れない間は「覆う」を判定できないので、両方 false として渡す = 手動優先
    public static func choose(hasManual: Bool, manualCovers: Bool,
                              hasTiles: Bool, tilesCover: Bool) -> MapSource {
        if hasTiles && tilesCover && !(hasManual && manualCovers) { return .tiles }
        if hasManual { return .manual }
        if hasTiles { return .tiles }
        return .none
    }
}
