import Foundation
import SQLite3

/// GeoPackage(Geofabrik の "free" 配布形式)から道路を読む。
///
/// なぜ必要か: Geofabrik は .osm.pbf と GeoPackage の両方を配布しており、
/// GeoPackage は SQLite なので osmium では読めない。一方で
/// **道路の種別が `fclass` 列に既に入っている**ため、タグ解釈が不要で扱いは易しい。
///
/// GPKG のジオメトリ列は「GP ヘッダ + 標準 WKB」。
/// ヘッダは 8 バイト(magic 2 + version 1 + flags 1 + srs_id 4)に続いて
/// flags のビット 1〜3 が示す長さの外接矩形が入る。
enum GeoPackage {
    struct Road {
        let fclass: String
        let maxspeed: Int?
        /// [(緯度, 経度)] の列。複数線分の場合は分割して複数の Road になる
        let points: [(lat: Double, lon: Double)]
    }

    enum Failure: Error, CustomStringConvertible {
        case open(String)
        case query(String)
        var description: String {
            switch self {
            case .open(let m): "GeoPackage を開けません: \(m)"
            case .query(let m): "問い合わせに失敗: \(m)"
            }
        }
    }

    /// 外接矩形が指定の範囲と交わる道路だけを返す。
    /// RTree 索引が無いため全走査になるが、ヘッダの外接矩形だけ見て捨てるので
    /// ジオメトリ本体の復号は候補に絞られる。
    static func roads(at path: String, table: String,
                      minLat: Double, maxLat: Double,
                      minLon: Double, maxLon: Double,
                      onProgress: (Int, Int) -> Void) throws -> [Road] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw Failure.open(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT fclass, maxspeed, geom FROM \(table)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Road] = []
        var scanned = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            scanned += 1
            if scanned % 200_000 == 0 { onProgress(scanned, out.count) }
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: blob, count: length)
            guard let g = decode(data) else { continue }
            // 外接矩形が範囲外なら本体を見ない
            guard g.maxLon >= minLon, g.minLon <= maxLon,
                  g.maxLat >= minLat, g.minLat <= maxLat else { continue }

            let fclass = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let speed = sqlite3_column_type(stmt, 1) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 1))
            for line in g.lines where line.count >= 2 {
                out.append(Road(fclass: fclass, maxspeed: speed, points: line))
            }
        }
        onProgress(scanned, out.count)
        return out
    }

    // MARK: - GPKG ジオメトリの復号

    private struct Geometry {
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var lines: [[(lat: Double, lon: Double)]] = []
    }

    private static func decode(_ data: Data) -> Geometry? {
        guard data.count > 8, data[0] == 0x47, data[1] == 0x50 else { return nil }  // "GP"
        let flags = data[3]
        // ビット 1〜3 が外接矩形の種類。0=無し, 1=XY(32B), 2=XYZ(48B), 3=XYM(48B), 4=XYZM(64B)
        let envelopeBytes: Int
        switch (flags >> 1) & 0x07 {
        case 0: envelopeBytes = 0
        case 1: envelopeBytes = 32
        case 2, 3: envelopeBytes = 48
        case 4: envelopeBytes = 64
        default: return nil
        }
        var g = Geometry()
        let wkbStart = 8 + envelopeBytes
        guard data.count > wkbStart else { return nil }
        guard parseWKB(data, at: wkbStart, into: &g) != nil else { return nil }
        guard !g.lines.isEmpty else { return nil }
        return g
    }

    /// WKB を読み、線分列を集める。戻り値は次の読み出し位置
    private static func parseWKB(_ data: Data, at offset: Int, into g: inout Geometry) -> Int? {
        guard data.count >= offset + 5 else { return nil }
        let little = data[offset] == 1
        guard let type = readUInt32(data, offset + 1, little) else { return nil }
        var cursor = offset + 5

        switch type {
        case 2:  // LineString
            guard let n = readUInt32(data, cursor, little) else { return nil }
            cursor += 4
            var line: [(lat: Double, lon: Double)] = []
            line.reserveCapacity(Int(n))
            for _ in 0..<Int(n) {
                guard let x = readDouble(data, cursor, little),
                      let y = readDouble(data, cursor + 8, little) else { return nil }
                cursor += 16
                // WKB は (x, y) = (経度, 緯度)
                line.append((lat: y, lon: x))
                g.minLon = min(g.minLon, x); g.maxLon = max(g.maxLon, x)
                g.minLat = min(g.minLat, y); g.maxLat = max(g.maxLat, y)
            }
            g.lines.append(line)
            return cursor

        case 5:  // MultiLineString
            guard let n = readUInt32(data, cursor, little) else { return nil }
            cursor += 4
            for _ in 0..<Int(n) {
                guard let next = parseWKB(data, at: cursor, into: &g) else { return nil }
                cursor = next
            }
            return cursor

        default:
            return nil
        }
    }

    private static func readUInt32(_ d: Data, _ o: Int, _ little: Bool) -> UInt32? {
        guard d.count >= o + 4 else { return nil }
        let v = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
        return little ? UInt32(littleEndian: v) : UInt32(bigEndian: v)
    }

    private static func readDouble(_ d: Data, _ o: Int, _ little: Bool) -> Double? {
        guard d.count >= o + 8 else { return nil }
        let bits = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
        return Double(bitPattern: little ? UInt64(littleEndian: bits) : UInt64(bigEndian: bits))
    }
}
