import Foundation

/// 経路図の枠。緯度経度を「左上を原点とするメートルの平面」に落とす。
/// 散歩スケール(数 km)なので等距円筒近似で足りる(Geo.nearestPointOnSegment と同じ考え方)。
public struct MapFrame: Equatable {
    public let northLat: Double
    public let southLat: Double
    public let westLon: Double
    public let eastLon: Double
    /// 経度 1 度あたりのメートル(枠の中央緯度で決める)
    public let metersPerDegreeLon: Double

    public init(northLat: Double, southLat: Double, westLon: Double, eastLon: Double,
                metersPerDegreeLon: Double) {
        self.northLat = northLat
        self.southLat = southLat
        self.westLon = westLon
        self.eastLon = eastLon
        self.metersPerDegreeLon = metersPerDegreeLon
    }

    public var widthM: Double { (eastLon - westLon) * metersPerDegreeLon }
    public var heightM: Double { (northLat - southLat) * Geo.metersPerDegreeLat }

    /// 枠の中でのメートル座標。x は東へ、y は南へ(**北が上**の図になる)
    public func point(_ p: GeoPoint) -> (x: Double, y: Double) {
        ((p.longitude - westLon) * metersPerDegreeLon,
         (northLat - p.latitude) * Geo.metersPerDegreeLat)
    }

    /// 線分が枠と重なりうるか。緯度経度の箱どうしで見る(図の下地を間引くための粗い判定)
    public func mayContain(_ a: GeoPoint, _ b: GeoPoint) -> Bool {
        min(a.latitude, b.latitude) <= northLat && max(a.latitude, b.latitude) >= southLat
            && min(a.longitude, b.longitude) <= eastLon && max(a.longitude, b.longitude) >= westLon
    }
}

/// 1 回の散歩の記録。**開発中の振り返りのために残す**。
///
/// なぜ要るか: 音だけの体験なので、歩いている最中に「いま何が起きたか」を書き留められない。
/// 帰ってから「3 番目の案内が道の無い方を指した」と言えるように、
/// 歩いた経路と**番号を振ったイベント**を残す(2026-08-21 の要望)。
/// 番号の単位は利用者の言う「n 回目のイベント」= 曲がる誘導 1 件に合わせる。
///
/// 端末内にのみ保存し、送信しない。紹介用の書き出し(Sources/Demo)はこの記録を読まない
/// (docs/04 プライバシー / docs/07)。
public struct WalkSummary: Codable, Equatable {
    /// 経路図に置く印
    public enum Mark: String, Codable, Equatable {
        /// 曲がる誘導。**これだけに番号を振る**
        case guidance
        case returnStart
        case extended
        case arrival
    }

    public struct Event: Codable, Equatable {
        /// 誘導だけに振る 1 起点の連番。他の印は nil
        public var number: Int?
        public var mark: Mark
        /// 印を置く場所。誘導は角そのもの
        public var at: GeoPoint
        /// 誘導が指した向き [deg]。図の矢印になる
        public var bearingDeg: Double?
        /// 散歩の開始からの経過 [sec]
        public var elapsedSec: Double
        /// 誘導の終わり方(TurnGuidance.Ending の生値など)。鳴っている間は nil
        public var ending: String?
        /// 帰路のイベントか
        public var onReturn: Bool

        public init(number: Int?, mark: Mark, at: GeoPoint, bearingDeg: Double?,
                    elapsedSec: Double, ending: String?, onReturn: Bool) {
            self.number = number
            self.mark = mark
            self.at = at
            self.bearingDeg = bearingDeg
            self.elapsedSec = elapsedSec
            self.ending = ending
            self.onReturn = onReturn
        }
    }

    public private(set) var startedAt: Date
    public private(set) var endedAt: Date?
    /// 出発時の自宅。図に印を置き、枠にも含める
    public private(set) var home: GeoPoint?
    public private(set) var track: [GeoPoint] = []
    public private(set) var events: [Event] = []
    /// 実経路長 [m]。**測るのは GaitMetrics の仕事**なので、閉じるときに受け取るだけ
    /// (同じ距離を 2 か所で数えない)
    public private(set) var pathLengthM: Double = 0
    /// 点を間引いた倍率。上限に達するたびに 2 倍になる
    private var thinScale: Double = 1
    private var guidanceCount = 0

    public init(startedAt: Date, home: GeoPoint?) {
        self.startedAt = startedAt
        self.home = home
    }

    /// 位置更新を経路に足す。`minSegmentM` 未満の動きは GPS の揺れとして捨てる
    /// (経路長と同じ基準を使う。図と距離が食い違わないため)。
    ///
    /// 点が `maxPoints` に達したら 1 つおきに間引き、以後の間隔を 2 倍にする。
    /// **長い散歩でも記録が伸び続けない**ようにするための上限で、
    /// 間引いても図の形は保たれる。
    public mutating func add(_ p: GeoPoint, minSegmentM: Double, maxPoints: Int) {
        if let last = track.last, Geo.distanceM(last, p) < minSegmentM * thinScale { return }
        track.append(p)
        guard maxPoints >= 2, track.count > maxPoints else { return }
        var kept = [GeoPoint]()
        kept.reserveCapacity(track.count / 2 + 1)
        for (i, q) in track.enumerated() where i.isMultiple(of: 2) { kept.append(q) }
        // 末尾は必ず残す。現在地が消えると図の末端が切れて見える
        if let tail = track.last, kept.last != tail { kept.append(tail) }
        track = kept
        thinScale *= 2
    }

    /// 曲がる誘導が始まった。**番号はここで振る**
    @discardableResult
    public mutating func startGuidance(at corner: GeoPoint, bearingDeg: Double,
                                       onReturn: Bool, now: Date) -> Int {
        guidanceCount += 1
        events.append(Event(number: guidanceCount, mark: .guidance, at: corner,
                            bearingDeg: bearingDeg,
                            elapsedSec: now.timeIntervalSince(startedAt),
                            ending: nil, onReturn: onReturn))
        return guidanceCount
    }

    /// まだ終わり方の書かれていない誘導に、終わり方を書き込む
    public mutating func finishGuidance(ending: String) {
        guard let i = events.lastIndex(where: { $0.mark == .guidance && $0.ending == nil })
        else { return }
        events[i].ending = ending
    }

    /// 誘導以外の印(帰路開始・延長・到着)
    public mutating func addMark(_ mark: Mark, at p: GeoPoint, onReturn: Bool, now: Date) {
        events.append(Event(number: nil, mark: mark, at: p, bearingDeg: nil,
                            elapsedSec: now.timeIntervalSince(startedAt),
                            ending: nil, onReturn: onReturn))
    }

    /// 記録を閉じる。距離は計測側(GaitMetrics)の値をそのまま受け取る
    public mutating func finish(at date: Date, pathLengthM: Double) {
        endedAt = date
        self.pathLengthM = pathLengthM
    }

    public var durationSec: Double { (endedAt ?? startedAt).timeIntervalSince(startedAt) }
    /// 番号の振られたイベント(利用者が「n 回目」と数える単位)
    public var guidanceEvents: [Event] { events.filter { $0.mark == .guidance } }

    /// 終わり方ごとの件数。従った / 断ったの割合を一目で見るため。
    /// 件数の多い順、同数なら名前順(表示が回ごとに入れ替わらないように)
    public func endingCounts() -> [(ending: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in guidanceEvents {
            counts[e.ending ?? "途中", default: 0] += 1
        }
        return counts.map { (ending: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.ending < $1.ending }
    }

    /// 経路図の枠。経路・イベント・自宅をすべて含み、周囲に `marginM` の余白を取る。
    /// ごく短い散歩でも `minSpanM` までは広げる(点が 1 つでも図として成立させる)
    public func frame(marginM: Double, minSpanM: Double) -> MapFrame? {
        var points = track
        points.append(contentsOf: events.map(\.at))
        if let h = home { points.append(h) }
        guard let first = points.first else { return nil }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }
        let lonScale = Geo.metersPerDegreeLat * cos((minLat + maxLat) / 2 * .pi / 180)
        guard lonScale > 0 else { return nil }

        func expand(_ lo: Double, _ hi: Double, perDegree: Double) -> (lo: Double, hi: Double) {
            let spanM = (hi - lo) * perDegree
            let wantM = max(spanM + 2 * marginM, minSpanM)
            let addDeg = (wantM - spanM) / 2 / perDegree
            return (lo - addDeg, hi + addDeg)
        }
        let lat = expand(minLat, maxLat, perDegree: Geo.metersPerDegreeLat)
        let lon = expand(minLon, maxLon, perDegree: lonScale)
        return MapFrame(northLat: lat.hi, southLat: lat.lo, westLon: lon.lo, eastLon: lon.hi,
                        metersPerDegreeLon: lonScale)
    }
}
