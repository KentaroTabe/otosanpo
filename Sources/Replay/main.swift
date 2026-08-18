import Foundation

/// 記録したフィールドログを再生して、Core の純粋ロジックを歩かずに検証するツール。
///
/// なぜ要るか: 実装を変えるたびに実機で散歩するのは検証の回数が過剰になる。
/// 位置・速度・精度が 1 件ずつ残っていれば、経路長・迂回率・提案の判定といった
/// 純粋計算は記録の再生で確かめられる。実機テストは
/// 「音がどう聞こえるか」「ジェスチャが通るか」など再生では代替できないものに絞る。
///
/// 使い方: scripts/replay_log.sh [ログファイル]

// MARK: - ログの読み取り

struct LoggedFix {
    let time: Date
    let state: String
    let point: GeoPoint
    let speedMps: Double?
    let courseDeg: Double?
    let accuracyM: Double?
}

/// "…速度=1.23m/s…" のように、キーの直後の数値を取り出す。単位や括弧は無視される
func numberAfter(_ key: String, in s: String) -> Double? {
    guard let r = s.range(of: key) else { return nil }
    let rest = s[r.upperBound...]
    var digits = ""
    for ch in rest {
        if ch.isNumber || ch == "." || (ch == "-" && digits.isEmpty) {
            digits.append(ch)
        } else {
            break
        }
    }
    return Double(digits)
}

/// 「yaw 生値 27°」を含む行(応答待ち中のモーション行と誤検出候補)から yaw を拾う
func readYaw(_ path: String) -> [(time: Date, yawDeg: Double)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [(time: Date, yawDeg: Double)] = []
    for line in text.split(separator: "\n") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 5, cols[4].contains("yaw 生値 ") else { continue }
        guard let t = formatter.date(from: cols[0]),
              let y = numberAfter("yaw 生値 ", in: cols[4]) else { continue }
        out.append((t, y))
    }
    return out
}

func readFixes(_ path: String) -> [LoggedFix] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("ログを読めません: \(path)\n".utf8))
        exit(1)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var out: [LoggedFix] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 5, cols[4].hasPrefix("fix ") else { continue }
        guard let time = formatter.date(from: cols[0]),
              let lat = Double(cols[2]), let lon = Double(cols[3]) else { continue }
        let msg = cols[4]
        out.append(LoggedFix(
            time: time,
            state: cols[1],
            point: GeoPoint(latitude: lat, longitude: lon),
            speedMps: numberAfter("速度=", in: msg),
            courseDeg: numberAfter("course=", in: msg),
            accuracyM: numberAfter("水平精度=", in: msg)
        ))
    }
    return out
}

// MARK: - 再生

/// 与えた条件で GaitMetrics を回し直す。実機と同じ Core のコードを使う
func replay(_ fixes: [LoggedFix], limits: GaitMetrics.Limits) -> GaitMetrics {
    var m = GaitMetrics()
    for f in fixes {
        m.add(f.point, speedMps: f.speedMps, accuracyM: f.accuracyM, limits: limits)
    }
    return m
}

func describe(_ label: String, _ m: GaitMetrics, straightLineM: Double, elapsedMin: Double) {
    let detour = m.detourFactor(straightLineM: straightLineM)
    let speed = m.averageMovingSpeedMPerMin
    // 速度の積分から求めた移動距離。経路長がこれを大きく超えていれば水増しを疑う
    let integrated = speed.map { $0 * elapsedMin }
    print(String(format: "  %-28@ 経路長=%6.0fm 迂回率=%@ 平均速度=%@ 速度積分=%@ 除外=%d件",
                 label as NSString,
                 m.pathLengthM,
                 detour.map { String(format: "%.2f", $0) } ?? "-",
                 speed.map { String(format: "%.0fm/min", $0) } ?? "-",
                 integrated.map { String(format: "%.0fm", $0) } ?? "-",
                 m.rejectedSamples))
}

// MARK: - 本体

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("使い方: replay <ログファイル> [設定JSON]\n".utf8))
    exit(1)
}
let logPath = args[1]
let configPath = args.count >= 3 ? args[2] : "config/parameters.json"

let all = readFixes(logPath)
guard !all.isEmpty else {
    print("fix 行がありません。位置更新を 1 件ずつ残す版でログを取り直してください。")
    print("(この行は 2026-08-17 以降のビルドから記録されます)")
    exit(0)
}

let params: AppParameters
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    params = try decoder.decode(AppParameters.self, from: data)
} catch {
    FileHandle.standardError.write(Data("設定を読めません: \(configPath) (\(error))\n".utf8))
    exit(1)
}

print("ログ: \(logPath)")
print("fix 行: \(all.count) 件")

let returning = all.filter { $0.state == "returning" }
print("うち帰路: \(returning.count) 件")

// 帰路が短い記録(机上テストなど)では迂回率の節を飛ばす。
// **ここで exit しない**。以降のスナップ・yaw の節は帰路が無くても意味を持つ
let b = params.budget
if let first = returning.first, let last = returning.last, returning.count > 2 {
// 自宅座標はログに無いため、到着地点(最後の fix)を自宅とみなす。
// 到着判定は arrival_radius_m 以内で成立しているので、その誤差の範囲で近似できる
let straight = Geo.distanceM(first.point, last.point)
let elapsedMin = last.time.timeIntervalSince(first.time) / 60
print(String(format: "帰路: 直線=%.0fm 所要=%.1f分 (自宅は到着地点で近似)", straight, elapsedMin))

print("\n== 実機の設定で再生 ==")
describe("現行(精度\(Int(b.maxAccuracyForMetricsM))m/区間\(Int(b.pathSegmentMinM))m)",
         replay(returning, limits: GaitMetrics.Limits(
            minMovingSpeedMps: b.minMovingSpeedMPerS,
            minSegmentM: b.pathSegmentMinM,
            maxAccuracyM: b.maxAccuracyForMetricsM)),
         straightLineM: straight, elapsedMin: elapsedMin)

print("\n== フィルタの寄与を切り分け ==")
let variants: [(String, Double, Double)] = [
    ("フィルタなし", 0, .greatestFiniteMagnitude),
    ("区間フィルタのみ", b.pathSegmentMinM, .greatestFiniteMagnitude),
    ("精度フィルタのみ", 0, b.maxAccuracyForMetricsM),
    ("両方", b.pathSegmentMinM, b.maxAccuracyForMetricsM),
]
for (label, seg, acc) in variants {
    describe(label, replay(returning, limits: GaitMetrics.Limits(
        minMovingSpeedMps: b.minMovingSpeedMPerS, minSegmentM: seg, maxAccuracyM: acc)),
             straightLineM: straight, elapsedMin: elapsedMin)
}

print("\n== 精度の上限を振る ==")
for acc in [10.0, 15.0, 20.0, 30.0, 50.0] {
    describe(String(format: "精度上限 %.0fm", acc),
             replay(returning, limits: GaitMetrics.Limits(
                minMovingSpeedMps: b.minMovingSpeedMPerS,
                minSegmentM: b.pathSegmentMinM, maxAccuracyM: acc)),
             straightLineM: straight, elapsedMin: elapsedMin)
}

print("\n迂回率は「経路長 / 直線距離」。速度積分より経路長が大きく上回る条件は、"
      + "GPS の揺れを経路長として数えている疑いがある。")
} else {
    print("帰路の fix が \(returning.count) 件しかないため、迂回率の節は省略")
}

// MARK: - 経路データがあれば、道路スナップと提案を再生する

/// ログの時刻表示に合わせる(HH:mm:ss)
let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

let mapPath = args.count >= 4 ? args[3] : "maps/otosanpo-map.json"
let loadedMap = FileManager.default.contents(atPath: mapPath)
    .flatMap { try? JSONDecoder().decode(WalkMap.self, from: $0) }

let r = params.route
if let walkMap = loadedMap {
let graph = WalkGraph(map: walkMap, cellSizeM: r.mapIndexCellSizeM)
print("\n== 道路スナップの再生 ==")
print("地図: 中心=(\(walkMap.center.latitude), \(walkMap.center.longitude))"
      + " 半径=\(Int(walkMap.radiusM))m 生成=\(walkMap.generated)"
      + " 節点=\(walkMap.nodes.count) 道=\(walkMap.ways.count)")

let inMap = all.filter { walkMap.covers($0.point) }
print("圏内の fix: \(inMap.count) / \(all.count) 件")

var snapped = 0
var snapSum = 0.0
var snapMax = 0.0
var bearingAgree = 0
var bearingChecked = 0
var byClass: [WayClass: Int] = [:]

for f in inMap {
    guard let s = graph.snap(f.point, maxDistanceM: r.snapMaxDistanceM) else { continue }
    snapped += 1
    snapSum += s.distanceM
    snapMax = max(snapMax, s.distanceM)
    byClass[walkMap.ways[s.wayIndex].cls, default: 0] += 1
    // course があるなら、道の向きと一致しているかを見る(前後どちらでも「沿っている」)
    if let course = f.courseDeg, course >= 0 {
        bearingChecked += 1
        let d = abs(Geo.angularDiffDeg(s.bearingDeg, course))
        if min(d, 180 - d) <= 30 { bearingAgree += 1 }
    }
}

if inMap.isEmpty {
    print("圏内の fix がありません。地図の中心が散歩の場所と合っているか確認してください。")
} else {
    let rate = Double(snapped) / Double(inMap.count) * 100
    print(String(format: "道に乗った: %d 件 (%.0f%%) / 平均 %.1fm・最大 %.1fm (上限 %.0fm)",
                 snapped, rate, snapped > 0 ? snapSum / Double(snapped) : 0,
                 snapMax, r.snapMaxDistanceM))
    if bearingChecked > 0 {
        print(String(format: "道の向きと course が 30° 以内で一致: %d / %d 件 (%.0f%%)",
                     bearingAgree, bearingChecked,
                     Double(bearingAgree) / Double(bearingChecked) * 100))
    }
    for c in WayClass.allCases {
        print("  \(c): \(byClass[c] ?? 0) 件")
    }
}

// MARK: - 提案の再生(交差点でどう判断したか)

print("\n== 提案の再生(交差点接近の検出 + 分岐の選択)==")
var grid = VisitGrid(cellSizeM: r.cellSizeM, halfLifeDays: r.visitHalfLifeDays)
var intersectionsSeen = 0
var choices: [String] = []
var lastChoiceAt: GeoPoint?

for f in inMap where f.state == "wandering" {
    grid.recordVisit(at: f.point, date: f.time)
    guard let course = f.courseDeg, course >= 0 else { continue }
    guard let x = graph.upcomingIntersection(from: f.point, bearingDeg: course,
                                             withinM: r.intersectionLookaheadM) else { continue }
    intersectionsSeen += 1
    // 直前に提案した地点から離れていなければ鳴らさない(実機と同じ間引き)
    if let last = lastChoiceAt, Geo.distanceM(last, f.point) < r.suggestionMinTravelM { continue }
    guard let c = BranchSuggester.choose(intersection: x, travelBearingDeg: course,
                                         position: f.point, home: walkMap.center,
                                         grid: grid, homewardBias: 0,
                                         route: r, now: f.time) else { continue }
    lastChoiceAt = f.point
    choices.append(String(format: "  %@ 交差点まで %.0fm / 分岐 %d 本 → 相対 %+.0f° (%@, 横断 %d) score=%.2f",
                          clock.string(from: f.time), x.distanceM, x.branches.count,
                          c.relativeBearingDeg, "\(c.branch.cls)", c.branch.crossCost, c.score))
}

print("交差点に接近した回数: \(intersectionsSeen)")
print("提案した回数: \(choices.count)")
for line in choices.prefix(30) { print(line) }
if choices.count > 30 { print("  (以下 \(choices.count - 30) 件省略)") }
print("\n自宅座標はログに無いため、帰宅バイアスは 0 として再生している"
      + "(交差点検出と分岐選択の確認が目的)。")
} else {
    print("\n経路データが無いため、スナップの再生は省略(\(mapPath))")
    print("scripts/build_map.sh で生成すると、この先も再生できます。")
}


// MARK: - CoreMotion の yaw の符号を実測から決める

/// 顔の向きの推定(HeadingFusion)は、CoreMotion の yaw と方位の**回転の向きが揃っている**
/// ことを前提にしている。CoreMotion は反時計回りが正、方位は時計回りが正なので、
/// 揃っていなければ首を右に向けたときに推定は左へ動く(2026-08-18 の実測で疑われた)。
///
/// 屋内で数字を読んで判断する代わりに、**歩行中の記録から自動で決める**。
/// 角を曲がれば頭も体も同じ向きに回るので、Δyaw と Δcourse の符号が揃うかを数えればよい。
print("\n== yaw の符号(HeadingFusion の前提)==")
/// 「頭向き yaw=12.3° course=45.6°」の対を読む。対がそのまま揃うので判定が素直
func readHeadingPairs(_ path: String) -> [(time: Date, yawDeg: Double, courseDeg: Double)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [(time: Date, yawDeg: Double, courseDeg: Double)] = []
    for line in text.split(separator: "\n") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 5, cols[4].hasPrefix("頭向き ") else { continue }
        guard let t = f.date(from: cols[0]),
              let y = numberAfter("yaw=", in: cols[4]),
              let c = numberAfter("course=", in: cols[4]) else { continue }
        out.append((t, y, c))
    }
    return out
}

let pairs = readHeadingPairs(logPath)
if pairs.count >= 10 {
    var agree = 0, used = 0
    for i in 1..<pairs.count {
        let dt = pairs[i].time.timeIntervalSince(pairs[i - 1].time)
        guard dt > 0, dt <= 6 else { continue }
        let dYaw = Geo.angularDiffDeg(pairs[i].yawDeg, pairs[i - 1].yawDeg)
        let dCourse = Geo.angularDiffDeg(pairs[i].courseDeg, pairs[i - 1].courseDeg)
        // はっきり回った対だけ数える。小さい変化は雑音
        guard abs(dYaw) >= 10, abs(dCourse) >= 10 else { continue }
        used += 1
        if (dYaw > 0) == (dCourse > 0) { agree += 1 }
    }
    if used >= 5 {
        let rate = Double(agree) / Double(used) * 100
        print(String(format: "  「頭向き」の対 %d 件のうち符号が一致: %d 件 (%.0f%%)", used, agree, rate))
        if rate >= 70 {
            print("  → 符号は揃っている。baseline_alpha の追従が遅すぎた側を疑う。")
        } else if rate <= 30 {
            print("  → 符号が反転している。yaw を負にしてから使う必要がある。")
        } else {
            print("  → 判定できない。")
        }
        exit(0)
    }
    print("  「頭向き」の対が \(used) 件しか使えないため、古い方式で判定する")
}

let yaws = readYaw(logPath)
if yaws.count < 10 {
    print("  yaw を含む行が足りません(\(yaws.count) 件)。")
    print("  この判定には歩行中の記録が要る(机上のテストでは曲がらないので判定できない)。")
} else {
    /// ±180 を跨ぐ差を -180..180 に畳む
    func delta(_ a: Double, _ b: Double) -> Double { Geo.angularDiffDeg(a, b) }

    var agree = 0, disagree = 0, used = 0
    var i = 1
    while i < yaws.count {
        let t0 = yaws[i - 1].time, t1 = yaws[i].time
        let dt = t1.timeIntervalSince(t0)
        // 間が空きすぎた対は、間に何が起きたか分からないので使わない
        guard dt > 0, dt <= 3 else { i += 1; continue }
        let dYaw = delta(yaws[i].yawDeg, yaws[i - 1].yawDeg)
        // 小さすぎる変化は雑音。はっきり回った対だけ数える
        guard abs(dYaw) >= 10 else { i += 1; continue }
        // 同じ時刻に最も近い fix の course を引く
        func course(near t: Date) -> Double? {
            var best: (d: TimeInterval, c: Double)?
            for f in all {
                guard let c = f.courseDeg, c >= 0 else { continue }
                let d = abs(f.time.timeIntervalSince(t))
                if d <= 2, best == nil || d < best!.d { best = (d, c) }
            }
            return best?.c
        }
        guard let c0 = course(near: t0), let c1 = course(near: t1) else { i += 1; continue }
        let dCourse = delta(c1, c0)
        guard abs(dCourse) >= 10 else { i += 1; continue }
        used += 1
        if (dYaw > 0) == (dCourse > 0) { agree += 1 } else { disagree += 1 }
        i += 1
    }

    if used < 5 {
        print("  判定に使える対が \(used) 件しかありません。曲がる場面を含む散歩の記録が要ります。")
    } else {
        let rate = Double(agree) / Double(used) * 100
        print(String(format: "  はっきり回った対 %d 件のうち、Δyaw と Δcourse の符号が一致: %d 件 (%.0f%%)",
                     used, agree, rate))
        if rate >= 70 {
            print("  → 符号は揃っている。HeadingFusion の前提は正しい。")
            print("     基準線の追従が遅すぎた可能性を疑う(baseline_alpha)。")
        } else if rate <= 30 {
            print("  → 符号が反転している。yaw を負にしてから basis に入れる必要がある。")
        } else {
            print("  → 判定できない。対の数を増やすか、別の指標が要る。")
        }
    }
}
