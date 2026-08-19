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

/// ログの時刻表示に合わせる(HH:mm:ss)
let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

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

/// ログには複数回の散歩が混ざりうる(アプリ内の「ログを消去」を押し忘れた場合)。
/// **まとめて 1 本の帰路として計算すると無意味な値になる**
/// (2026-08-18 の 2 回分混在ログで迂回率 4.63 が出た)。
/// 区切りは「帰路 → 散策に戻った」か「記録が大きく途切れた」で判定する。
func splitSessions(_ fixes: [LoggedFix]) -> [[LoggedFix]] {
    var out: [[LoggedFix]] = []
    var current: [LoggedFix] = []
    for f in fixes {
        if let prev = current.last {
            let gap = f.time.timeIntervalSince(prev.time)
            let restarted = (prev.state == "returning" && f.state == "wandering")
            if restarted || gap > 120 {
                out.append(current)
                current = []
            }
        }
        current.append(f)
    }
    if !current.isEmpty { out.append(current) }
    return out
}

/// 1 回の散歩の帰路。直線距離は「自宅 = 到着地点(最後の fix)」で近似する
/// (到着判定は arrival_radius_m 以内で成立しているので、その誤差に収まる)
struct ReturnLeg {
    let fixes: [LoggedFix]
    let straightM: Double
    let elapsedMin: Double
}

func returnLeg(of session: [LoggedFix]) -> ReturnLeg? {
    let r = session.filter { $0.state == "returning" }
    guard let first = r.first, let last = r.last, r.count > 2 else { return nil }
    return ReturnLeg(fixes: r,
                     straightM: Geo.distanceM(first.point, last.point),
                     elapsedMin: last.time.timeIntervalSince(first.time) / 60)
}

let sessions = splitSessions(all)
let legs = sessions.compactMap(returnLeg(of:))
print("含まれる散歩: \(sessions.count) 回 / 帰路の取れた回: \(legs.count)")

let b = params.budget
let currentLimits = GaitMetrics.Limits(minMovingSpeedMps: b.minMovingSpeedMPerS,
                                       minSegmentM: b.pathSegmentMinM,
                                       maxAccuracyM: b.maxAccuracyForMetricsM)

if !legs.isEmpty {
print("\n== 実機の設定で再生(帰路ごと)==")
for (i, leg) in legs.enumerated() {
    print(String(format: "帰路 %d: 直線=%.0fm 所要=%.1f分 (%@ 〜)",
                 i + 1, leg.straightM, leg.elapsedMin,
                 clock.string(from: leg.fixes[0].time)))
    describe("  現行(精度\(Int(b.maxAccuracyForMetricsM))m/区間\(Int(b.pathSegmentMinM))m)",
             replay(leg.fixes, limits: currentLimits),
             straightLineM: leg.straightM, elapsedMin: leg.elapsedMin)
}

// パラメータの振り直しは最後の帰路だけで行う(全帰路ぶん出すと読めない)
let leg = legs[legs.count - 1]
let straight = leg.straightM
let elapsedMin = leg.elapsedMin
let returning = leg.fixes
print("\n以下の振り直しは最後の帰路(直線 \(Int(straight))m)を対象にする。")

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
    print("帰路として使える区間が無いため、迂回率の節は省略")
}

// MARK: - 経路データがあれば、道路スナップと提案を再生する

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

// 端末の VisitGrid は過去の散歩ぶん馴染み度を溜めている。
// 同じ状態を再現しないと「なぜ鳴らないか」を再生で判定できないので、
// 手元にある過去のログを時系列順にすべて流し込んでから評価する
var historyFixes = 0
if let files = try? FileManager.default.contentsOfDirectory(atPath: "field-logs") {
    for name in files.filter({ $0.hasSuffix(".tsv") }).sorted()
    where !logPath.hasSuffix(name) {
        for f in readFixes("field-logs/" + name)
        where f.state == "wandering" || f.state == "returning" {
            grid.recordVisit(at: f.point, date: f.time)
            historyFixes += 1
        }
    }
}
print("過去のログから馴染み度を再構成: \(historyFixes) 件")

/// 却下の理由を数える。「鳴らない」の内訳が分からないと調整できない
var rejected: [String: Int] = [:]
var bestScores: [Double] = []
var intersectionsSeen = 0
var choices: [String] = []
var lastChoiceAt: GeoPoint?

// 誘導の再生。**進行方位を基準にしたときに左右がどれだけ付くか**を測る。
// 2026-08-19 の指摘「案内音の左右が非常に分かりにくい」の主因は顔基準の破綻だったが、
// 進行基準に戻したときに十分な左右が出るのかは別問題で、これは歩かずに測れる
let gp = TurnGuidance.Params(
    startDistanceM: r.intersectionLookaheadM, peakBeforeM: params.audio.guidancePeakBeforeM,
    intervalSec: params.audio.guidanceIntervalSec, gainFar: params.audio.guidanceGainFar,
    gainNear: params.audio.guidanceGainNear, endDistanceM: params.audio.guidanceEndDistanceM,
    leftBehindM: params.audio.guidanceLeftBehindM, turnedWithinDeg: r.branchStraightDeg,
    closingTones: params.audio.guidanceClosingTones)
var active: (g: TurnGuidance, at: Date, rels: [Double])?
/// 交差点までの「道なり / 直線」。1.0 に近いほど、指す向きが道と一致している
var detourRatios: [Double] = []
var guidanceReports: [String] = []
/// 左右の付き方の集計。|相対| が小さい音は「ほぼ正面」で左右の手がかりを持たない
var relCenter = 0, relMid = 0, relSide = 0

for f in inMap where f.state == "wandering" {
    grid.recordVisit(at: f.point, date: f.time)
    guard let course = f.courseDeg, course >= 0 else { continue }

    // 誘導中は次の提案を評価しない(実機と同じ)
    if active != nil {
        switch active!.g.next(position: f.point, travelBearingDeg: course, p: gp) {
        case .play(let s):
            let rel = Geo.angularDiffDeg(s.targetBearingDeg, course)
            active!.rels.append(rel)
            if abs(rel) < 20 { relCenter += 1 } else if abs(rel) < 45 { relMid += 1 } else { relSide += 1 }
        case .finished(let ending):
            let rels = active!.rels
            let centered = rels.filter { abs($0) < 20 }.count
            guidanceReports.append(String(
                format: "  %@ %2d音 相対 %+.0f°→%+.0f° 最大 %.0f° / ほぼ正面(<20°) %d音 (%.0f%%) %@",
                clock.string(from: active!.at), rels.count,
                rels.first ?? 0, rels.last ?? 0, rels.map { abs($0) }.max() ?? 0,
                centered, rels.isEmpty ? 0 : Double(centered) / Double(rels.count) * 100,
                ending.rawValue))
            active = nil
        }
        continue
    }

    guard let x = graph.upcomingIntersection(from: f.point, bearingDeg: course,
                                             withinM: r.intersectionLookaheadM,
                                             snapMaxDistanceM: r.snapMaxDistanceM) else {
        continue
    }
    intersectionsSeen += 1
    // 交差点までの**直線距離と道なりの距離**を比べる。大きく違えば、
    // その交差点は街区の向こう側にある(=そこを指すと私有地を突っ切る)
    if let s = graph.snap(f.point, maxDistanceM: r.snapMaxDistanceM) {
        let straight = Geo.distanceM(s.point, x.point)
        if straight > 1 {
            detourRatios.append(x.distanceM / straight)
        }
    }
    // 直前に提案した地点から離れていなければ鳴らさない(実機と同じ間引き)
    if let last = lastChoiceAt, Geo.distanceM(last, f.point) < r.suggestionMinTravelM { continue }

    // 却下の内訳は **BranchSuggester 自身に答えさせる**。
    // ここで同じ式を書き写すと、本体のゲートを変えたときに内訳だけが古い判定を報告する
    // (実測: 比ゲートへ変えた後も「スコア不足(< 0.15)」と出ていた)
    let decision = BranchSuggester.decide(intersection: x, travelBearingDeg: course,
                                          position: f.point, home: walkMap.center,
                                          grid: grid, homewardBias: 0,
                                          route: r, now: f.time)
    if let best = decision.best { bestScores.append(best.score) }
    switch decision {
    case .silent(let why, _):
        rejected[why.rawValue, default: 0] += 1
        continue
    case .suggest(let c):
        bestScores.append(c.score)
        lastChoiceAt = f.point
        choices.append(String(format: "  %@ 交差点まで %.0fm / 分岐 %d 本 → 相対 %+.0f° (%@, 横断 %d) score=%.2f",
                              clock.string(from: f.time), x.distanceM, x.branches.count,
                              c.relativeBearingDeg, "\(c.branch.cls)", c.branch.crossCost, c.score))
        active = (TurnGuidance(corner: x.point, branchBearingDeg: c.branch.bearingDeg,
                               distanceM: x.distanceM), f.time, [])
    }
}

print("交差点に接近した回数: \(intersectionsSeen)")
if !detourRatios.isEmpty {
    let sorted = detourRatios.sorted()
    // 1.0 = 交差点が真っ直ぐ先にある。大きいほど、直線で指すと道から外れる
    print(String(format: "交差点までの 道なり/直線: 中央 %.2f / 最大 %.2f(%d 件)",
                 sorted[sorted.count / 2], sorted.last!, sorted.count))
    let far = sorted.filter { $0 > 1.5 }.count
    print(String(format: "  1.5 倍を超える(街区を回り込む位置)= %d 件 (%.0f%%)",
                 far, Double(far) / Double(sorted.count) * 100))
}
print("提案した回数: \(choices.count)")
if !rejected.isEmpty {
    print("却下の内訳(移動距離の間引きを通った分):")
    for (k, v) in rejected.sorted(by: { $0.value > $1.value }) { print("  \(k): \(v) 回") }
}
if !bestScores.isEmpty {
    let sorted = bestScores.sorted()
    // 分岐選択に絶対下限は無い(相対比で判定する)。分布は「どのくらいの新鮮さの
    // 土地を歩いているか」を見るための材料として出す
    print(String(format: "接近した交差点での最良スコアの分布: 最小 %.2f / 中央 %.2f / 最大 %.2f",
                 sorted.first!, sorted[sorted.count / 2], sorted.last!))
}
for line in choices.prefix(30) { print(line) }
if choices.count > 30 { print("  (以下 \(choices.count - 30) 件省略)") }
print("\n自宅座標はログに無いため、帰宅バイアスは 0 として再生している"
      + "(交差点検出と分岐選択の確認が目的)。")

// MARK: - 誘導の左右(進行方位を基準にした場合)

print("\n== 誘導の再生(左右の付き方・進行基準)==")
if guidanceReports.isEmpty {
    print("  誘導イベントがありません")
} else {
    let total = relCenter + relMid + relSide
    print(String(format: "  %d 件 / 音 %d 発の内訳: ほぼ正面(<20°) %d (%.0f%%) / "
                 + "斜め(20〜45°) %d (%.0f%%) / 横(≥45°) %d (%.0f%%)",
                 guidanceReports.count, total,
                 relCenter, Double(relCenter) / Double(total) * 100,
                 relMid, Double(relMid) / Double(total) * 100,
                 relSide, Double(relSide) / Double(total) * 100))
    for line in guidanceReports.prefix(20) { print(line) }
    if guidanceReports.count > 20 { print("  (以下 \(guidanceReports.count - 20) 件省略)") }
    print("  ※ 「ほぼ正面」の音は左右の手がかりを持たない。角そのものを指す設計上、"
          + "接近中は正面寄りになる")
}

// MARK: - 行き先の地帯
/// 「音の鳴る方に歩くと面白い散歩ができる」の後半。
/// 過去のログで馴染んだ地帯を避け、道のある地帯を選べているかを歩かずに確かめる。
    print("\n== 行き先の地帯(広域の選定)==")
    let started = Date()
    let zoneMap = ZoneMap(map: walkMap, zoneSizeM: r.zoneSizeM)
    print(String(format: "  地帯 %d 個(%.0fm 角・構築 %.2f 秒)",
                 zoneMap.zones.count, r.zoneSizeM, -started.timeIntervalSinceNow))
    let roads = zoneMap.zones.map(\.roadLengthM).sorted()
    if !roads.isEmpty {
        print(String(format: "  地帯あたりの道の総延長: 最小 %.0fm / 中央 %.0fm / 最大 %.0fm(下限 %.0fm)",
                     roads.first!, roads[roads.count / 2], roads.last!, r.zoneMinRoadM))
        let usable = roads.filter { $0 >= r.zoneMinRoadM }.count
        print(String(format: "  行き先になりうる地帯: %d 個 (%.0f%%)",
                     usable, Double(usable) / Double(roads.count) * 100))
    }
    // 馴染み度は上で再構成した grid をそのまま使う(過去の散歩ぶんが入っている)
    let home = walkMap.center
    // 実機と同じく、選定は許容半径の内側(soft zone)で行う。
    // 縁ぎりぎりの地帯を選ぶと、許容半径が縮んだ数秒後に失効する
    print("  10 分の散歩は許容 377m、30 分なら 1450m 程度。選定は許容 × "
          + String(format: "%.1f", b.softZoneRatio) + " の内側で行う")
    for allowed in [377.0, 700.0, 1450.0] {
        let pick = allowed * b.softZoneRatio
        let t = zoneMap.chooseTarget(from: home, home: home, allowedRadiusM: pick,
                                     grid: grid, now: Date(timeIntervalSince1970: 1_786_000_000),
                                     p: r.zoneParams)
        guard let t else {
            print(String(format: "  許容 %4.0fm(選定 %3.0fm): 選べる地帯なし", allowed, pick))
            continue
        }
        print(String(format: "  許容 %4.0fm(選定 %3.0fm・最短 %3.0fm)→ %4.0fm 先 方位 %3.0f°"
                     + "(新鮮さ %.2f・道 %.0fm)",
                     allowed, pick, r.zoneParams.effectiveMinDistanceM(allowedRadiusM: pick),
                     t.distanceM, Geo.bearingDeg(from: home, to: t.zone.center),
                     t.novelty, t.zone.roadLengthM))
    }
    print("  ※ 現在地を自宅としたときの選定。新鮮さは過去のログから再構成した馴染み度による")
} else {
    print("\n経路データが無いため、スナップの再生は省略(\(mapPath))")
    print("scripts/build_map.sh で生成すると、この先も再生できます。")
}


// MARK: - 帰宅推定(経路長 vs 直線 × 迂回率)

/// 記録した帰路を使って、2 つの見積もり方の**誤差**を比べる。
/// 帰路は目的地が決まっている唯一の区間なので、正解(実際にかかった時間)が分かる。
if let walkMap = loadedMap, !legs.isEmpty {
    let graph = WalkGraph(map: walkMap, cellSizeM: r.mapIndexCellSizeM)
    print("\n== 帰宅推定の測り比べ(帰路の開始時点で何分と見積もるか)==")
    print("  正解 = 実際にかかった時間。経路長は自宅を到着地点で近似している")
    print(String(format: "  %8@ %7@ %9@ %9@ %11@ %11@",
                 "開始" as NSString, "正解" as NSString, "直線" as NSString,
                 "経路" as NSString, "直線の誤差" as NSString, "経路の誤差" as NSString))
    var straightErr = 0.0, routeErr = 0.0, counted = 0
    for leg in legs {
        guard let first = leg.fixes.first, let last = leg.fixes.last else { continue }
        // 自宅は到着地点で近似する(実機の到着判定は arrival_radius_m 以内で成立している)
        // 経路の場は散歩の開始時に 1 回だけ解く。実機で待たされないか確かめるため計測する
        let started = Date()
        guard let field = RouteField(
            graph: graph, goal: last.point, snapMaxDistanceM: r.snapMaxDistanceM,
            weights: RouteField.Weights(crossCostWeight: r.crossCostWeight,
                                        wayClassWeight: r.wayClassWeight)) else { continue }
        if counted == 0 {
            print(String(format: "  (経路の場の構築: %.2f 秒 / 到達できる節点 %d / %d)",
                         -started.timeIntervalSinceNow, field.reachableNodes,
                         walkMap.nodes.count))
        }
        guard let routeM = field.pathLengthM(from: first.point, graph: graph) else { continue }
        // 速度はその帰路の実測を使う(速度の推定そのものは別の話なので固定しない)
        let m = replay(leg.fixes, limits: currentLimits)
        let v = m.averageMovingSpeedMPerMin ?? b.walkingSpeedMPerMin
        let byStraight = ReturnBudget.estimatedReturnMin(.straight(leg.straightM),
                                                         speedMPerMin: v, p: b)
        let byRoute = ReturnBudget.estimatedReturnMin(.route(routeM), speedMPerMin: v, p: b)
        straightErr += abs(byStraight - leg.elapsedMin)
        routeErr += abs(byRoute - leg.elapsedMin)
        counted += 1
        print(String(format: "  %8@ %6.1f分 %8.1f分 %8.1f分 %+10.1f分 %+10.1f分",
                     clock.string(from: first.time) as NSString, leg.elapsedMin,
                     byStraight, byRoute, byStraight - leg.elapsedMin, byRoute - leg.elapsedMin))
    }
    if counted > 0 {
        print(String(format: "  平均誤差: 直線 %.1f分 / 経路 %.1f分(%d 本)",
                     straightErr / Double(counted), routeErr / Double(counted), counted))
    }
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

/// 曲がった対について、yaw が旋回を追えているかを調べる。
///
/// **符号の一致率だけでは判定できない**(2026-08-19 の失敗)。一致率は ± しか見ないので、
/// yaw が旋回とほとんど無関係でも偏りがあれば「反転」と読めてしまう。実際
/// 「一致 26% → 符号は −1」と結論して顔基準を有効にしたところ、左右が壊れた。
///
/// 大きさで見るのが正しい。`raw = s·yaw − course` は HeadingFusion の基準線の入力で、
/// **体ごとの旋回では動かないはず**。動くなら、その符号では旋回を打ち消せていない。
/// `|Δraw|` が `|Δcourse|` と同程度なら、yaw は旋回の情報を持っていない。
struct YawStats {
    var used = 0
    var agree = 0
    var sumCourse = 0.0
    var sumRawNeg = 0.0
    var sumRawPos = 0.0

    var meanCourse: Double { used > 0 ? sumCourse / Double(used) : 0 }
    var meanRawNeg: Double { used > 0 ? sumRawNeg / Double(used) : 0 }
    var meanRawPos: Double { used > 0 ? sumRawPos / Double(used) : 0 }
    var agreeRate: Double { used > 0 ? Double(agree) / Double(used) * 100 : 0 }
}

func yawStats(_ pairs: [(time: Date, yawDeg: Double, courseDeg: Double)],
              turnThresholdDeg: Double) -> YawStats {
    var s = YawStats()
    guard pairs.count >= 2 else { return s }
    for i in 1..<pairs.count {
        let a = pairs[i - 1], b = pairs[i]
        let dt = b.time.timeIntervalSince(a.time)
        // 間が空きすぎた対は、間に何が起きたか分からないので使わない
        guard dt > 0, dt <= 6 else { continue }
        let dYaw = Geo.angularDiffDeg(b.yawDeg, a.yawDeg)
        let dCourse = Geo.angularDiffDeg(b.courseDeg, a.courseDeg)
        guard abs(dYaw) >= 10, abs(dCourse) >= turnThresholdDeg else { continue }
        s.used += 1
        s.sumCourse += abs(dCourse)
        if (dYaw > 0) == (dCourse > 0) { s.agree += 1 }
        for sign in [-1.0, 1.0] {
            let rawA = Geo.normalizeDeg(sign * a.yawDeg - a.courseDeg)
            let rawB = Geo.normalizeDeg(sign * b.yawDeg - b.courseDeg)
            let d = abs(Geo.angularDiffDeg(rawB, rawA))
            if sign < 0 { s.sumRawNeg += d } else { s.sumRawPos += d }
        }
    }
    return s
}

// **手元の全ログを合わせて判定する。** 1 回の散歩では曲がる対が数十件しか取れず、
// 判定が宙ぶらりんになる(前回は 45% で結論が出なかった)
var allPairs: [(time: Date, yawDeg: Double, courseDeg: Double)] = []
var pairFiles = 0
if let files = try? FileManager.default.contentsOfDirectory(atPath: "field-logs") {
    for name in files.filter({ $0.hasSuffix(".tsv") }).sorted() {
        let p = readHeadingPairs("field-logs/" + name)
        guard !p.isEmpty else { continue }
        pairFiles += 1
        // ファイルを跨ぐ対を作らないよう、境界に大きな時間差を挟む
        // (countSignAgreement の dt <= 6 秒の条件で自然に落ちる)
        allPairs.append(contentsOf: p)
        allPairs.append((time: p[p.count - 1].time.addingTimeInterval(3600),
                         yawDeg: 0, courseDeg: 0))
    }
}
if allPairs.isEmpty { allPairs = readHeadingPairs(logPath) }

print("  対象: field-logs/ の \(pairFiles) ファイル(「頭向き」行 \(allPairs.count) 件)")
print("  曲がった対で、raw = s·yaw − course がどれだけ動くか(小さいほどその符号が正しい):")
print("    下限   対   |Δcourse|  |Δraw| s=-1  |Δraw| s=+1  符号一致")
for threshold in [20.0, 30.0, 45.0] {
    let s = yawStats(allPairs, turnThresholdDeg: threshold)
    guard s.used > 0 else {
        print(String(format: "    ≥%3.0f°   0", threshold))
        continue
    }
    print(String(format: "    ≥%3.0f° %4d %9.1f° %11.1f° %11.1f° %8.0f%%",
                 threshold, s.used, s.meanCourse, s.meanRawNeg, s.meanRawPos, s.agreeRate))
}

let v = yawStats(allPairs, turnThresholdDeg: 30)
if v.used < 20 {
    print("  判定に使える対が \(v.used) 件しかありません。曲がる場面を含む散歩の記録が要ります。")
} else {
    let best = min(v.meanRawNeg, v.meanRawPos)
    // 旋回を打ち消せているなら |Δraw| は |Δcourse| よりはっきり小さくなるはず。
    // 半分に届かないなら、どちらの符号でも yaw は基準として使えない
    if best > v.meanCourse * 0.5 {
        print(String(format: "  → **yaw は旋回を追えていない**(|Δraw| %.0f° に対し |Δcourse| %.0f°)。",
                     best, v.meanCourse))
        print("     符号の問題ではないので yaw_sign では直らない。use_head_orientation は false。")
    } else if v.meanRawNeg < v.meanRawPos {
        print("  → 符号は反転している。yaw_sign を -1 にする。")
    } else {
        print("  → 符号は揃っている。yaw_sign は +1 のままでよい。")
    }
}
