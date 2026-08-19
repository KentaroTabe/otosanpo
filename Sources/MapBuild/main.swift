import Foundation

/// osmium が出した GeoJSON を、端末に置く `WalkMap` 形式へ変換する開発用ツール。
///
/// なぜ Swift で書くか: 形式の定義(`WalkMap`)をアプリと共有するため。
/// jq などで組むと、鍵名や種別の数値がアプリ側と食い違っても気づけない。
///
/// 使い方: scripts/build_map.sh から呼ばれる
///   mapbuild <入力geojson か .gpkg> <出力json> <中心緯度> <中心経度> <半径m> <生成日>

// MARK: - OSM の highway タグ → WayClass

/// 歩ける道だけを通す。ここに無いタグは捨てる。
/// 幹線を含めるのは、実際に歩く経路に現れるため(横断コストで抑制する)
func wayClass(for highway: String) -> WayClass? {
    switch highway {
    case "footway", "path", "pedestrian", "steps", "track", "cycleway", "bridleway":
        return .footway
    // Geofabrik の GeoPackage は未舗装路を track_grade1..5 に細分する
    case let v where v.hasPrefix("track_grade"):
        return .footway
    case "residential", "living_street", "service", "unclassified", "road", "unknown":
        return .residential
    case "primary", "secondary", "tertiary", "trunk",
         "primary_link", "secondary_link", "tertiary_link", "trunk_link":
        return .arterial
    default:
        return nil
    }
}

/// 横断コストの階級。幹線ほど、車線が多いほど渡るのが負担になる
func crossCost(highway: String, lanes: Int?, hasCrossingSignal: Bool) -> Int {
    var cost: Int
    switch wayClass(for: highway) {
    case .footway: cost = 0
    case .residential: cost = 1
    case .arterial: cost = 3
    case nil: cost = 0
    }
    if let lanes, lanes >= 4 { cost += 1 }
    // 信号があれば渡れるので負担は下がる(待ち時間はあるが危険は減る)
    if hasCrossingSignal, cost > 0 { cost -= 1 }
    return cost
}

// MARK: - 引数

let args = CommandLine.arguments
guard args.count >= 7,
      let centerLat = Double(args[3]), let centerLon = Double(args[4]),
      let radiusM = Double(args[5]) else {
    FileHandle.standardError.write(Data(
        "使い方: mapbuild <入力geojson> <出力json> <中心緯度> <中心経度> <半径m> <生成日>\n".utf8))
    exit(1)
}
let inputPath = args[1]
let outputPath = args[2]
let generated = args[6]
let center = GeoPoint(latitude: centerLat, longitude: centerLon)

// MARK: - 読み取り

let isGeoPackage = inputPath.hasSuffix(".gpkg")

/// osmium export の出力は FeatureCollection か GeoJSONSeq のどちらか。
/// **GeoJSONSeq は RFC 8142 で各レコードの先頭に RS(0x1E)が入る**。
/// これを外さないと JSON として読めない(合成データで試すと気づけない落とし穴)。
func features(from data: Data) -> [[String: Any]] {
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let list = obj["features"] as? [[String: Any]] {
        return list
    }
    var out: [[String: Any]] = []
    let text = String(decoding: data, as: UTF8.self)
    // 改行と RS の両方で区切り、前後の制御文字と空白を落とす
    for record in text.split(whereSeparator: { $0 == "\n" || $0 == "\u{1E}" }) {
        let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        out.append(obj)
    }
    return out
}

// MARK: - 変換

/// 同じ座標を 1 つの節点に畳む。交差点の共有と、サイズ削減のため。
/// 座標は 7 桁(約 1 cm)に丸めて突き合わせる
var nodeIndex: [String: Int] = [:]
var nodes: [[Double]] = []
func nodeNumber(lat: Double, lon: Double) -> Int {
    let key = String(format: "%.7f,%.7f", lat, lon)
    if let i = nodeIndex[key] { return i }
    nodes.append([(lat * 1e7).rounded() / 1e7, (lon * 1e7).rounded() / 1e7])
    nodeIndex[key] = nodes.count - 1
    return nodes.count - 1
}

var ways: [WalkMap.Way] = []
var skippedTag = 0
var skippedOutside = 0

if isGeoPackage {
    // 円を覆う矩形を先に出し、GeoPackage 側は外接矩形でふるいにかける
    let dLat = radiusM / Geo.metersPerDegreeLat
    let dLon = radiusM / (Geo.metersPerDegreeLat * cos(centerLat * .pi / 180))
    do {
        let roads = try GeoPackage.roads(
            at: inputPath, table: "gis_osm_roads_free",
            minLat: centerLat - dLat, maxLat: centerLat + dLat,
            minLon: centerLon - dLon, maxLon: centerLon + dLon,
            onProgress: { scanned, kept in
                FileHandle.standardError.write(
                    Data("  走査 \(scanned) 行 / 範囲内 \(kept) 本\n".utf8))
            })
        for r in roads {
            guard let cls = wayClass(for: r.fclass) else {
                skippedTag += 1
                continue
            }
            var indices: [Int] = []
            for pt in r.points {
                let p = GeoPoint(latitude: pt.lat, longitude: pt.lon)
                guard Geo.distanceM(center, p) <= radiusM else { continue }
                indices.append(nodeNumber(lat: pt.lat, lon: pt.lon))
            }
            guard indices.count >= 2 else {
                skippedOutside += 1
                continue
            }
            // free 版の GeoPackage に車線数は無い。最高速度を道の規模の代理にする
            let lanesProxy = (r.maxspeed ?? 0) >= 60 ? 4 : nil
            ways.append(WalkMap.Way(n: indices, cls: cls,
                                    cross: crossCost(highway: r.fclass, lanes: lanesProxy,
                                                     hasCrossingSignal: false)))
        }
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
} else {
    guard let data = FileManager.default.contents(atPath: inputPath) else {
        FileHandle.standardError.write(Data("入力を読めません: \(inputPath)\n".utf8))
        exit(1)
    }
    for f in features(from: data) {
        guard let props = f["properties"] as? [String: Any],
              let highway = props["highway"] as? String,
              let cls = wayClass(for: highway) else {
            skippedTag += 1
            continue
        }
        guard let geom = f["geometry"] as? [String: Any],
              let type = geom["type"] as? String, type == "LineString",
              let coords = geom["coordinates"] as? [[Double]] else { continue }

        let lanes = (props["lanes"] as? String).flatMap { Int($0) } ?? (props["lanes"] as? Int)
        let signal = (props["crossing"] as? String) == "traffic_signals"

        // 円の外に完全に出ている way は落とす(osmium は矩形で切るため角が余る)
        var indices: [Int] = []
        for c in coords where c.count >= 2 {
            // GeoJSON は [経度, 緯度] の順
            let p = GeoPoint(latitude: c[1], longitude: c[0])
            guard Geo.distanceM(center, p) <= radiusM else { continue }
            indices.append(nodeNumber(lat: c[1], lon: c[0]))
        }
        guard indices.count >= 2 else {
            skippedOutside += 1
            continue
        }
        ways.append(WalkMap.Way(n: indices, cls: cls,
                                cross: crossCost(highway: highway, lanes: lanes,
                                                 hasCrossingSignal: signal)))
    }
}

let map = WalkMap(center: center, radiusM: radiusM, generated: generated,
                  nodes: nodes, ways: ways)

do {
    let encoder = JSONEncoder()
    let out = try encoder.encode(map)
    try out.write(to: URL(fileURLWithPath: outputPath))
    let mb = Double(out.count) / 1_048_576
    print(String(format: "書き出しました: %@ (%.1f MB)", outputPath, mb))
    print("節点=\(nodes.count) 道=\(ways.count)"
          + " / 対象外のタグで除外=\(skippedTag) 円外で除外=\(skippedOutside)")
    let byClass = Dictionary(grouping: ways, by: { $0.cls })
    for c in WayClass.allCases {
        print("  \(c): \(byClass[c]?.count ?? 0) 本")
    }
} catch {
    FileHandle.standardError.write(Data("書き出しに失敗: \(error)\n".utf8))
    exit(1)
}
