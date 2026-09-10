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
    /// course の許容誤差。**製品と同じ有効性判定を再現するのに要る**
    let courseAccuracyDeg: Double?
    /// この行を書いた時点での fix の古さ [sec]。後の時刻での古さは経過時間を足して求める
    let ageSec: Double?
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
            accuracyM: numberAfter("水平精度=", in: msg),
            courseAccuracyDeg: numberAfter("course精度=", in: msg),
            ageSec: numberAfter("経過=", in: msg)
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
var grid = VisitGrid(cellSizeM: r.cellSizeM, halfLifeM: r.visitHalfLifeM)

// 端末の VisitGrid は過去の散歩ぶん馴染み度を溜めている。
// 同じ状態を再現しないと「なぜ鳴らないか」を再生で判定できないので、
// 手元にある過去のログを時系列順にすべて流し込んでから評価する
var historyFixes = 0
if let files = try? FileManager.default.contentsOfDirectory(atPath: "field-logs") {
    for name in files.filter({ $0.hasSuffix(".tsv") }).sorted()
    where !logPath.hasSuffix(name) {
        // 実機と同じく、歩いた分だけ減衰の時計を進める。
        // これをやらないと過去の記録が一切減衰せず、馴染み度が実機と食い違う
        var previous: GeoPoint?
        for f in readFixes("field-logs/" + name)
        where f.state == "wandering" || f.state == "returning" {
            if let q = previous {
                let d = Geo.distanceM(q, f.point)
                if d >= b.pathSegmentMinM {
                    grid.advance(byM: d)
                    previous = f.point
                }
            } else {
                previous = f.point
            }
            grid.recordVisit(at: f.point)
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
/// 予告の 1 音目が指した向きに、実際に道があったか
var announceChecks: [(distanceM: Double, relativeDeg: Double, nearestRoadM: Double)] = []
var lastChoiceAt: GeoPoint?

// 誘導の再生。**進行方位を基準にしたときに左右がどれだけ付くか**を測る。
// 2026-08-19 の指摘「案内音の左右が非常に分かりにくい」の主因は顔基準の破綻だったが、
// 進行基準に戻したときに十分な左右が出るのかは別問題で、これは歩かずに測れる
let gp = TurnGuidance.Params(
    startDistanceM: r.intersectionLookaheadM, peakBeforeM: params.audio.guidancePeakBeforeM,
    intervalSec: params.audio.guidanceIntervalSec, gainFar: params.audio.guidanceGainFar,
    gainNear: params.audio.guidanceGainNear, endDistanceM: params.audio.guidanceEndDistanceM,
    leftBehindM: params.audio.guidanceLeftBehindM, turnedWithinDeg: r.branchStraightDeg,
    closingTones: params.audio.guidanceClosingTones,
    announceTones: params.audio.guidanceAnnounceTones,
    abandonBehindDeg: params.audio.guidanceAbandonBehindDeg)
var active: (g: TurnGuidance, at: Date, rels: [Double])?
/// 交差点までの「道なり / 直線」。1.0 に近いほど、指す向きが道と一致している
var detourRatios: [Double] = []
var guidanceReports: [String] = []
/// 左右の付き方の集計。|相対| が小さい音は「ほぼ正面」で左右の手がかりを持たない
var relCenter = 0, relMid = 0, relSide = 0

var odometerPrevious: GeoPoint?
for f in inMap where f.state == "wandering" {
    if let q = odometerPrevious {
        let d = Geo.distanceM(q, f.point)
        if d >= b.pathSegmentMinM {
            grid.advance(byM: d)
            odometerPrevious = f.point
        }
    } else {
        odometerPrevious = f.point
    }
    grid.recordVisit(at: f.point)
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
                                          grid: grid, homewardBias: 0, graph: graph,
                                          route: r)
    if let best = decision.best { bestScores.append(best.score) }
    switch decision {
    case .silent(let why, _):
        rejected[why.rawValue, default: 0] += 1
        continue
    case .suggest(let c):
        bestScores.append(c.score)
        lastChoiceAt = f.point
        // **予告の 1 音目は「曲がる先の方位」を、いま立っている場所から鳴らす。**
        // 角がまだ 30m 先にあると、その向きの先には道が無い(家や塀)。
        // 利用者の「道の存在しない方向に向かっていた」はこれの疑いがあるので、
        // その向きに実際の道があるかを地図で確かめる
        //
        // **「近くに道がある」では判定にならない。** 街区は 30〜50m 間隔なので、
        // どの向きへ 10m 進んでも何らかの道の近くにはなる。いま立っている道自体も拾う。
        // 「その向きに**進める**か」を見るには、**道の向きが指した向きと揃っている**
        // ことまで要る。15m 以上先(いまの道では説明できない距離)で探す
        var nearestRoadM = Double.greatestFiniteMagnitude
        var step = 15.0
        while step <= r.intersectionLookaheadM {
            let q = Geo.destination(from: f.point, bearingDeg: c.branch.bearingDeg,
                                    distanceM: step)
            if let s = graph.snap(q, maxDistanceM: 10),
               abs(Geo.angularDiffDeg(s.bearingDeg, c.branch.bearingDeg)) <= 35
                || abs(Geo.angularDiffDeg(s.bearingDeg, c.branch.bearingDeg + 180)) <= 35 {
                nearestRoadM = min(nearestRoadM, s.distanceM)
            }
            step += 5
        }
        announceChecks.append((distanceM: x.distanceM,
                               relativeDeg: c.relativeBearingDeg,
                               nearestRoadM: nearestRoadM))
        let roadLabel = nearestRoadM <= 10
            ? String(format: "予告の先に道あり(%.0fm)", nearestRoadM)
            : "**予告の先に進める道なし**"
        choices.append(String(format: "  %@ 交差点まで %.0fm / 分岐 %d 本 → 相対 %+.0f° (%@, 横断 %d) score=%.2f / %@",
                              clock.string(from: f.time), x.distanceM, x.branches.count,
                              c.relativeBearingDeg, "\(c.branch.cls)", c.branch.crossCost,
                              c.score, roadLabel))
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
if !announceChecks.isEmpty {
    // **予告の 1 音目は「角に着いてから踏み出す向き」を、いま立っている場所から鳴らす。**
    // 角が遠いほど、その向きの先には道が無い(家や塀を指す)。
    let noRoad = announceChecks.filter { !$0.nearestRoadM.isFinite || $0.nearestRoadM > 15 }
    print(String(format: "\n予告(1 音目)の向きの先に道があるか: 道が無い %d / %d 件 (%.0f%%)",
                 noRoad.count, announceChecks.count,
                 Double(noRoad.count) / Double(announceChecks.count) * 100))
    let farAndSide = announceChecks.filter { $0.distanceM >= 25 && abs($0.relativeDeg) >= 60 }
    print(String(format: "  角が 25m 以上先で、かつ横 60° 以上を指した回: %d 件",
                 farAndSide.count))
    if !noRoad.isEmpty {
        let avgD = noRoad.reduce(0) { $0 + $1.distanceM } / Double(noRoad.count)
        let avgR = noRoad.reduce(0) { $0 + abs($1.relativeDeg) } / Double(noRoad.count)
        print(String(format: "  道が無かった回の平均: 角まで %.0fm / 相対 %.0f°", avgD, avgR))
    }
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
                                     grid: grid,
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
    print(String(format: "  %8@ %7@ %9@ %9@ %11@ %11@ %11@",
                 "開始" as NSString, "正解" as NSString, "直線" as NSString,
                 "経路" as NSString, "直線の誤差" as NSString, "経路の誤差" as NSString,
                 "実装の誤差" as NSString))
    print("  「実装」= いま動いている選び方(経路長を直線の倍数で抑えたもの)")
    var straightErr = 0.0, routeErr = 0.0, actualErr = 0.0, counted = 0
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
        // 実装が実際に選ぶ距離。経路長が直線の倍数を超えたら抑えられる
        let chosen = ReturnBudget.distance(routeM: routeM, straightM: leg.straightM, p: b)
        let byActual = ReturnBudget.estimatedReturnMin(chosen, speedMPerMin: v, p: b)
        straightErr += abs(byStraight - leg.elapsedMin)
        routeErr += abs(byRoute - leg.elapsedMin)
        actualErr += abs(byActual - leg.elapsedMin)
        counted += 1
        print(String(format: "  %8@ %6.1f分 %8.1f分 %8.1f分 %+10.1f分 %+10.1f分 %+10.1f分 [%@]",
                     clock.string(from: first.time) as NSString, leg.elapsedMin,
                     byStraight, byRoute, byStraight - leg.elapsedMin, byRoute - leg.elapsedMin,
                     byActual - leg.elapsedMin, chosen.label as NSString))
    }
    if counted > 0 {
        print(String(format: "  平均誤差: 直線 %.1f分 / 経路 %.1f分 / 実装 %.1f分(%d 本)",
                     straightErr / Double(counted), routeErr / Double(counted),
                     actualErr / Double(counted), counted))
    }
}

// MARK: - 経路長が過大になる原因の切り分け

/// 2026-08-27 の帰路で、経路長 1609m に対し実際に歩いたのは 688m だった。
/// 原因の候補は 2 つあり、切り分けないとどちらを直せばいいか決まらない。
///
/// 1. **重みによる迂回**: 横断と幹線を嫌って遠回りの経路が選ばれている
/// 2. **地図の欠落**: 実際に歩いた道が地図で繋がっておらず、遠回りしか出せない
///
/// 重み 0 の場を並べれば分けられる。重み 0 の経路長が実測に近ければ 1、
/// 重み 0 でも過大なら 2。重みの割り増しは最大 1.52 倍なので、
/// それを超える過大は原理的に 1 だけでは説明できない。
if let walkMap = loadedMap, !legs.isEmpty {
    let graph = WalkGraph(map: walkMap, cellSizeM: r.mapIndexCellSizeM)
    print("\n== 経路長の内訳(重みの迂回 / 地図の欠落)==")
    let plainWeights = RouteField.Weights(crossCostWeight: 0, wayClassWeight: 0)
    let realWeights = RouteField.Weights(crossCostWeight: r.crossCostWeight,
                                         wayClassWeight: r.wayClassWeight)
    for (i, leg) in legs.enumerated() {
        guard let first = leg.fixes.first, let last = leg.fixes.last,
              let weighted = RouteField(graph: graph, goal: last.point,
                                        snapMaxDistanceM: r.snapMaxDistanceM,
                                        weights: realWeights),
              let plain = RouteField(graph: graph, goal: last.point,
                                     snapMaxDistanceM: r.snapMaxDistanceM,
                                     weights: plainWeights) else { continue }

        // 各 fix の時点で「あと何 m 歩いたか」を出す。経路長の見積もりと突き合わせる正解になる
        var cumulative: [Double] = []
        var m = GaitMetrics()
        for f in leg.fixes {
            m.add(f.point, speedMps: f.speedMps, accuracyM: f.accuracyM, limits: currentLimits)
            cumulative.append(m.pathLengthM)
        }
        let total = cumulative.last ?? 0

        let w0 = weighted.pathLengthM(from: first.point, graph: graph)
        let p0 = plain.pathLengthM(from: first.point, graph: graph)
        print(String(format: "帰路 %d: 直線=%.0fm 実際に歩いた=%.0fm", i + 1, leg.straightM, total))
        print(String(format: "  重みあり経路=%@ / 重みなし経路(実距離の最短)=%@",
                     w0.map { String(format: "%.0fm", $0) } ?? "-",
                     p0.map { String(format: "%.0fm", $0) } ?? "-"))
        if let w0, let p0, p0 > 0 {
            print(String(format: "  重みの寄与=%.2f 倍(上限 1.52)/ 最短が実測を超える分=%.2f 倍",
                         w0 / p0, p0 / max(total, 1)))
        }
        print("  経過とともにどう動くか(残り実距離 = 正解):")
        print(String(format: "  %8@ %10@ %12@ %12@ %10@",
                     "時刻" as NSString, "残り実距離" as NSString, "重みあり経路" as NSString,
                     "重みなし経路" as NSString, "直線" as NSString))
        for (j, f) in leg.fixes.enumerated() where j % 20 == 0 {
            let remaining = total - cumulative[j]
            let wm = weighted.pathLengthM(from: f.point, graph: graph)
            let pm = plain.pathLengthM(from: f.point, graph: graph)
            print(String(format: "  %8@ %9.0fm %11@ %11@ %9.0fm",
                         clock.string(from: f.time) as NSString, remaining,
                         wm.map { String(format: "%.0fm", $0) } ?? "-" as NSString,
                         pm.map { String(format: "%.0fm", $0) } ?? "-" as NSString,
                         Geo.distanceM(f.point, last.point)))
        }

        // **散歩全体で「経路長 / 直線距離」の分布を見る。**
        // 跳ねが局所的なら比で弾ける。頻繁なら弾き方では足りず、地図か снап の作り直しが要る
        // 帰路の取れない散歩があると legs と sessions の番号がずれるので、
        // 一致している時だけ散歩全体を見る(この節は診断であって判定ではない)
        let wholeSession = sessions.count == legs.count ? sessions[i] : leg.fixes
        print("  散歩全体での 経路長/直線距離 の分布(自宅は到着地点で近似):")
        var ratios: [(Double, LoggedFix)] = []
        for f in wholeSession {
            let straightM = Geo.distanceM(f.point, last.point)
            guard straightM > 30, let rm = weighted.pathLengthM(from: f.point, graph: graph) else { continue }
            ratios.append((rm / straightM, f))
        }
        let sorted = ratios.map(\.0).sorted()
        func pct(_ q: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
        }
        print(String(format: "    %d 件 / 中央 %.2f / 90%% %.2f / 95%% %.2f / 最大 %.2f",
                     sorted.count, pct(0.5), pct(0.9), pct(0.95), sorted.last ?? 0))
        for limit in [1.8, 2.0, 2.5, 3.0] {
            let over = sorted.filter { $0 > limit }.count
            print(String(format: "    %.1f 倍を超える: %d 件 (%.1f%%)",
                         limit, over, 100 * Double(over) / Double(max(sorted.count, 1))))
        }
        // 跳ねている区間の時刻を出す。立ち止まり・幹線の反対側などと突き合わせるため
        let spikes = ratios.filter { $0.0 > 2.0 }
        if let head = spikes.first, let tail = spikes.last {
            print(String(format: "    2.0 倍超えの範囲: %@ 〜 %@(%d 件)",
                         clock.string(from: head.1.time) as NSString,
                         clock.string(from: tail.1.time) as NSString, spikes.count))
        }
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

// MARK: - 検算: course をならしてから測り直す(2026-08-21)
//
// 上の判定は GPS の course を「正解」として使っている。しかし実測の courseAccuracy は
// 40〜70° で、2 秒間隔の |Δcourse| ≥ 30° には**曲がっていない雑音**が相当混ざる。
// 雑音を正解にすれば、どんな頭の動きも「合っていない」と出る。
//
// そこで (a) course を前後 1 サンプルでならし、(b) 4〜8 秒離れた対で見る。
// 本当に曲がった区間だけが残るので、yaw が旋回を追えているかを公平に測れる。
func smoothedPairs(_ pairs: [(time: Date, yawDeg: Double, courseDeg: Double)])
    -> [(time: Date, yawDeg: Double, courseDeg: Double)] {
    guard pairs.count >= 3 else { return pairs }
    var out = pairs
    for i in 1..<(pairs.count - 1) {
        let window = [pairs[i - 1], pairs[i], pairs[i + 1]]
        // 隣が時間的に離れすぎていれば、ならさずそのまま使う
        guard window[2].time.timeIntervalSince(window[0].time) <= 8 else { continue }
        var x = 0.0, y = 0.0
        for w in window {
            x += cos(w.courseDeg * .pi / 180)
            y += sin(w.courseDeg * .pi / 180)
        }
        out[i].courseDeg = Geo.normalizeDeg(atan2(y, x) * 180 / .pi)
    }
    return out
}

/// 4〜8 秒離れた対で、持続した旋回だけを見る
func sustainedYawStats(_ pairs: [(time: Date, yawDeg: Double, courseDeg: Double)],
                       turnThresholdDeg: Double) -> YawStats {
    var s = YawStats()
    guard pairs.count >= 2 else { return s }
    for i in 0..<pairs.count {
        for j in (i + 1)..<pairs.count {
            let a = pairs[i], b = pairs[j]
            let dt = b.time.timeIntervalSince(a.time)
            if dt < 4 { continue }
            if dt > 8 { break }
            let dCourse = Geo.angularDiffDeg(b.courseDeg, a.courseDeg)
            guard abs(dCourse) >= turnThresholdDeg else { continue }
            s.used += 1
            s.sumCourse += abs(dCourse)
            let dYaw = Geo.angularDiffDeg(b.yawDeg, a.yawDeg)
            if (dYaw > 0) == (dCourse > 0) { s.agree += 1 }
            for sign in [-1.0, 1.0] {
                let rawA = Geo.normalizeDeg(sign * a.yawDeg - a.courseDeg)
                let rawB = Geo.normalizeDeg(sign * b.yawDeg - b.courseDeg)
                let d = abs(Geo.angularDiffDeg(rawB, rawA))
                if sign < 0 { s.sumRawNeg += d } else { s.sumRawPos += d }
            }
            break
        }
    }
    return s
}

print("\n  検算: course を平滑化し、4〜8 秒の持続した旋回だけで測り直す")
print("  (元の判定は 2 秒間隔の生 course を正解にしており、GPS の雑音を旋回と数えうる)")
print("    下限   対   |Δcourse|  |Δraw| s=-1  |Δraw| s=+1  符号一致")
let smoothed = smoothedPairs(allPairs)
for threshold in [30.0, 45.0, 60.0] {
    let s = sustainedYawStats(smoothed, turnThresholdDeg: threshold)
    guard s.used > 0 else {
        print(String(format: "    ≥%3.0f°   0", threshold))
        continue
    }
    print(String(format: "    ≥%3.0f° %4d %9.1f° %11.1f° %11.1f° %8.0f%%",
                 threshold, s.used, s.meanCourse, s.meanRawNeg, s.meanRawPos, s.agreeRate))
}
let sv = sustainedYawStats(smoothed, turnThresholdDeg: 45)
if sv.used >= 20 {
    let best = min(sv.meanRawNeg, sv.meanRawPos)
    if best > sv.meanCourse * 0.5 {
        print("  → 検算しても yaw は旋回を追えていない。結論は変わらない")
    } else {
        print(String(format: "  → **検算では yaw が旋回を追えている**(|Δraw| %.0f° < |Δcourse| %.0f°)。",
                     best, sv.meanCourse))
        print("     元の判定は GPS の雑音を旋回と数えていた可能性がある。要再検討")
    }
} else {
    print("  持続した旋回の対が \(sv.used) 件しかなく、検算では判定できない")
}

// MARK: - ジャイロ(角速度)は旋回を追えているか
//
// 姿勢(yaw)がだめでも、角速度そのものが追えていないとは限らない。
// 「回転」列は減衰なしの積分なので、旋回した区間で Δcourse と一致すれば
// **ジャイロは使える**ことになる(頭の向きの推定は HeadTracker が担う)。
// 2026-08-21 以降のログにのみ含まれる。
func readRotationPairs(_ path: String) -> [(time: Date, rotationDeg: Double, courseDeg: Double)] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [(time: Date, rotationDeg: Double, courseDeg: Double)] = []
    for line in text.split(separator: "\n") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 5, cols[4].hasPrefix("頭向き "),
              let t = f.date(from: cols[0]),
              let r = numberAfter("回転=", in: cols[4]),
              let c = numberAfter("course=", in: cols[4]) else { continue }
        out.append((time: t, rotationDeg: r, courseDeg: c))
    }
    return out
}

var rotationPairs: [(time: Date, rotationDeg: Double, courseDeg: Double)] = []
if let files = try? FileManager.default.contentsOfDirectory(atPath: "field-logs") {
    for name in files.filter({ $0.hasSuffix(".tsv") }).sorted() {
        rotationPairs.append(contentsOf: readRotationPairs("field-logs/" + name))
    }
}
if rotationPairs.isEmpty {
    print("\n  角速度の記録(「回転=」)はまだありません。2026-08-21 以降のログで測れます")
} else {
    var used = 0, sumCourse = 0.0, sumDiff = 0.0, agree = 0
    for i in 1..<rotationPairs.count {
        let a = rotationPairs[i - 1], b = rotationPairs[i]
        let dt = b.time.timeIntervalSince(a.time)
        guard dt > 0, dt <= 6 else { continue }
        let dCourse = Geo.angularDiffDeg(b.courseDeg, a.courseDeg)
        guard abs(dCourse) >= 30 else { continue }
        used += 1
        sumCourse += abs(dCourse)
        // 回転は「前回の記録からの積分」なので、b の値がその区間の頭の回転量
        sumDiff += abs(Geo.angularDiffDeg(b.rotationDeg, dCourse))
        if (b.rotationDeg > 0) == (dCourse > 0) { agree += 1 }
    }
    // **まず「回転」と「Δyaw」を突き合わせる。**
    // course を正解にすると「どちらも旋回を追えていない」としか言えないが、
    // 回転(ジャイロの積分)と Δyaw(姿勢の変化)は、世界を追えているかとは無関係に
    // **互いに一致するはず**である。どちらも「頭がどれだけ回ったか」を別経路で測ったもの。
    // 一致しなければ、読んでいる軸か符号が違う。
    var axisPairs = 0
    var sumDyaw = 0.0, sumGap = 0.0, sumGapFlipped = 0.0, axisAgree = 0
    for i in 1..<allPairs.count {
        let a = allPairs[i - 1], b = allPairs[i]
        let dt = b.time.timeIntervalSince(a.time)
        guard dt > 0, dt <= 6, i < rotationPairs.count else { continue }
        let dYaw = Geo.angularDiffDeg(b.yawDeg, a.yawDeg)
        let rot = rotationPairs[min(i, rotationPairs.count - 1)].rotationDeg
        guard abs(dYaw) >= 5 || abs(rot) >= 5 else { continue }
        axisPairs += 1
        sumDyaw += abs(dYaw)
        sumGap += abs(Geo.angularDiffDeg(rot, dYaw))
        sumGapFlipped += abs(Geo.angularDiffDeg(-rot, dYaw))
        if (rot > 0) == (dYaw > 0) { axisAgree += 1 }
    }
    if axisPairs > 20 {
        print("\n  ジャイロの軸と符号(回転 と Δyaw の突き合わせ・\(axisPairs) 区間)")
        print(String(format: "    |Δyaw| %.1f° / |回転 − Δyaw| %.1f° / |−回転 − Δyaw| %.1f° / 符号一致 %.0f%%",
                     sumDyaw / Double(axisPairs), sumGap / Double(axisPairs),
                     sumGapFlipped / Double(axisPairs),
                     100 * Double(axisAgree) / Double(axisPairs)))
        let straight = sumGap / Double(axisPairs)
        let flipped = sumGapFlipped / Double(axisPairs)
        if min(straight, flipped) > sumDyaw / Double(axisPairs) * 0.5 {
            print("    → 軸が違う。rotationRate.z は頭の鉛直軸ではない疑い")
        } else if flipped < straight {
            print("    → **符号が逆。head_rate_sign を反転させること**")
        } else {
            print("    → 軸も符号も合っている。ジャイロは頭の回転を取れている")
        }
    }

    print("\n  角速度の積分と course の比較(「回転」列・\(rotationPairs.count) 件)")
    if used == 0 {
        print("    曲がった区間がまだありません")
    } else {
        print(String(format: "    対 %d / |Δcourse| %.1f° / |回転 − Δcourse| %.1f° / 符号一致 %.0f%%",
                     used, sumCourse / Double(used), sumDiff / Double(used),
                     100 * Double(agree) / Double(used)))
        if sumDiff / Double(used) < sumCourse / Double(used) * 0.5 {
            print("    → **ジャイロは旋回を追えている。** 頭の向きの推定に使える")
        } else {
            print("    → ジャイロでも旋回に追随できていない。符号(head_rate_sign)も確かめること")
        }
    }
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

// MARK: - 頭部固定(学習・検疫・使用可能)を再生する
//
// docs/13 は「`頭方位` 行があるので閾値も学習の条件も再生で振り直せる(歩き直し不要)」と
// 約束していたが、**その道具は存在しなかった**(2026-09-08 に判明)。ここがその実装。
//
// 判定には**製品と同じ Core の `HeadMountFusion`** を使う。再生専用の複製を書くと
// 必ず本体とずれる(そして、ずれたことに気づかない)。

/// ログに残った 1 件の頭方位
struct LoggedHeadHeading {
    let time: Date
    /// 生の方位。旧形式では「補正後 + 補正値」から復元する
    let rawDeg: Double
    /// ログに残っていた学習値(照合用。学習前は nil)
    let loggedOffsetDeg: Double?
    /// ログに残っていた検疫の状態(照合用)
    let loggedState: String
    /// 旧形式から復元した値か
    let reconstructed: Bool
}

/// `頭方位` 行はあったが `raw=` も `heading=` も無くて使えなかった行数。
/// **0 件を「問題なし」と読ませない**ための材料(→ 受け入れ条件 E6)
var headLinesMissingHeading = 0

/// `頭方位` 行を読む。**新旧どちらの形式も読む**。
///
/// - 新形式: `raw=` を持つ(2026-09-08 以降)
/// - 旧形式: `heading=` は**補正後**の値。`補正=` が数値なら生値は `heading + 補正`、
///   `補正=学習中` なら補正されていないので `heading` がそのまま生値
func readHeadHeadings(_ path: String) -> [LoggedHeadHeading] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var out: [LoggedHeadHeading] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 5, cols[4].hasPrefix("頭方位 ") else { continue }
        guard let time = formatter.date(from: cols[0]) else { continue }
        let msg = cols[4]
        let offset = numberAfter("補正=", in: msg)   // 「学習中」なら nil
        // 状態は日本語ラベルなので数値抽出が使えない。区切りまでを切り出す
        var stateLabel = "-"
        if let r = msg.range(of: "状態=") {
            stateLabel = String(msg[r.upperBound...].prefix { !$0.isWhitespace })
        }
        if let raw = numberAfter("raw=", in: msg) {
            out.append(LoggedHeadHeading(time: time, rawDeg: raw, loggedOffsetDeg: offset,
                                         loggedState: stateLabel, reconstructed: false))
        } else if let corrected = numberAfter("heading=", in: msg) {
            let raw = Geo.normalizeDeg(corrected + (offset ?? 0))
            out.append(LoggedHeadHeading(time: time, rawDeg: raw, loggedOffsetDeg: offset,
                                         loggedState: stateLabel, reconstructed: true))
        } else {
            // **黙って捨てない。** 捨てた行を数えて、後で「何が足りないか」を言う
            headLinesMissingHeading += 1
        }
    }
    return out
}

let headSamples = readHeadHeadings(logPath)

// MARK: - ビーコンの指す向きの安定性(引き継ぎの有無で比べる)
//
// 2026-09-08 の散歩で、ビーコンの指す向きが **1.5 秒で 180° 往復**していた
// (274 発のうち 67 発が後ろを指した)。原因は、スナップも端点の選択も
// **前回の選択を見ていない**こと(docs/05)。ここはその前後を測る口。

print("\n== ビーコンの指す向きの安定性 ==")

if let beaconMap = loadedMap, let last = all.last {
    let graph = WalkGraph(map: beaconMap, cellSizeM: r.mapIndexCellSizeM)
    // 自宅は到着地点で近似する(実機の到着判定は arrival_radius_m 以内で成立している)
    if let field = RouteField(graph: graph, goal: last.point,
                              snapMaxDistanceM: r.snapMaxDistanceM,
                              weights: RouteField.Weights(
                                crossCostWeight: r.crossCostWeight,
                                wayClassWeight: r.wayClassWeight)) {

        // **帰路の fix だけを見る。** ビーコンが鳴るのは帰路だけで、
        // 散策中は自宅から遠ざかるので「経路が後ろを指す」のが正しい。
        // 混ぜると「後ろ向き」の数字が意味を失う(2026-09-09 に一度混ぜて誤った)
        let returning = all.filter { $0.state == "returning" }
        print("  対象: 帰路の fix \(returning.count) 件(全 \(all.count) 件)")

        /// 引き継ぎ設定を 1 つ与えて、帰路を通したときの跳びを数える
        func measure(_ tp: RouteField.TraceParams) -> (jumps: Int, reversals: Int,
                                                       behind: Int, samples: Int) {
            var trace: RouteField.Trace?
            var previous: Double?
            var jumps = 0, reversals = 0, behind = 0, samples = 0
            for f in returning {
                guard let step = field.nextStep(from: f.point, graph: graph,
                                                nodeToleranceM: r.nodeArrivalToleranceM,
                                                trace: trace, tp: tp) else { continue }
                trace = step.trace
                samples += 1
                if let prev = previous {
                    let jump = abs(Geo.angularDiffDeg(step.deg, prev))
                    if jump > 90 { jumps += 1 }
                    if jump > 150 { reversals += 1 }
                }
                previous = step.deg
                // 進行方位が取れている時だけ「後ろを指したか」を数える
                if let course = TravelDirection.rawCourse(
                    MotionFix(courseDeg: f.courseDeg, courseAccuracyDeg: f.courseAccuracyDeg,
                              speedMps: f.speedMps, compassHeadingDeg: nil,
                              ageSec: f.ageSec, horizontalAccuracyM: f.accuracyM),
                    params: params.location),
                   abs(Geo.angularDiffDeg(step.deg, course)) > 90 {
                    behind += 1
                }
            }
            return (jumps, reversals, behind, samples)
        }

        func row(_ label: String,
                 _ m: (jumps: Int, reversals: Int, behind: Int, samples: Int)) {
            let pct = m.samples > 0 ? 100 * Double(m.behind) / Double(m.samples) : 0
            print(String(format: "  %-16@ %8d %8d %8d(%.0f%%)", label as NSString,
                         m.jumps, m.reversals, m.behind, pct))
        }
        print(String(format: "  %-16@ %8@ %8@ %10@", "道 / 端点" as NSString,
                     "90°超" as NSString, "150°超" as NSString, "後ろ向き" as NSString))
        // **組み合わせを振る。** どちらの引き継ぎが効くのかは、片方ずつ動かさないと分からない
        let sweep: [(Double, Double)] = [(0, 0), (8, 0), (16, 0), (25, 0),
                                         (0, 10), (8, 10), (16, 10)]
        for (way, node) in sweep {
            let tp = RouteField.TraceParams(waySwitchMarginM: way, nodeSwitchMarginM: node)
            let label = way == 0 && node == 0
                ? "引き継ぎ無し" : String(format: "%.0fm / %.0fm", way, node)
            row(label, measure(tp))
        }
        print(String(format: "  いまの設定: 道 %.0fm / 端点 %.0fm",
                     r.waySwitchMarginM, r.nodeSwitchMarginM))
        print("  ※ 自宅は到着地点で近似している。ログの実機値と一致はしないが、"
              + "**同じ入力で前後を比べる**分には足りる")
    } else {
        print("  経路の場を作れませんでした(自宅が道に乗らない)")
    }
} else {
    print("  経路データがないので判定できません(maps/otosanpo-map.json が要ります)")
}

print("\n== 頭部固定の再生(学習・検疫・使用可能)==")

if headSamples.isEmpty {
    // **0 件を「問題なし」と読ませない。** 何が足りないのかを書く
    if headLinesMissingHeading > 0 {
        print("  判定不能: 「頭方位」行が \(headLinesMissingHeading) 件ありましたが、"
              + "raw= も heading= も入っていません。")
        print("  方位の列を持つ版でログを取り直してください。")
    } else {
        print("  「頭方位」行がありません。判定できません。")
        print("  この行は head_mount.enabled = true でビルドした版でしか記録されません。")
        print("  実験のビルドで歩いたログを取り込んでから、もう一度実行してください。")
    }
} else {
    let reconstructed = headSamples.filter(\.reconstructed).count
    print("  頭方位 行: \(headSamples.count) 件"
          + (reconstructed > 0 ? "(うち \(reconstructed) 件は旧形式から生値を復元)" : ""))
    print("  設定: \(configPath)")
    let hm = params.headMount
    print(String(format: "    distrust %.0f°/%.0fs・regain %.0fs・"
                 + "学習 標本 %.0f・半減期 %.0fs・R≥%.2f・鮮度 %.1fs",
                 hm.distrustDeg, hm.distrustSec, hm.regainSec,
                 hm.offsetMinSamples, hm.offsetHalfLifeSec,
                 hm.offsetMinConcentration, hm.staleSec))

    if headLinesMissingHeading > 0 {
        print("  ※ raw= も heading= も無い「頭方位」行を \(headLinesMissingHeading) 件"
              + "読み飛ばしました(この分は判定に入っていません)")
    }

    // **course は fix 行から作り直す。** ログの `頭方位 course=` は、
    // 2026-09-08 以前は「止まる直前の保持値」が混ざった値なので正解にしてはいけない
    let sortedFixes = all.sorted { $0.time < $1.time }
    // 製品と同じ規則で course を出すには、fix 行に速度と course が要る。
    // **欠けたまま「成立せず・0%」と出すと、実装の問題と読み違える**(→ E6)
    /// 判定を出してよいか。必要な列が丸ごと無ければ false にして、数字を出さない
    var headMountJudged = true
    let noSpeed = sortedFixes.filter { $0.speedMps == nil }.count
    let noCourse = sortedFixes.filter { $0.courseDeg == nil }.count
    if noSpeed == sortedFixes.count || noCourse == sortedFixes.count {
        // **全件欠けていれば計算しない。** 「0%・成立せず」を結果として出すと、
        // 実装の問題と読み違える(2026-09-09 の検証で指摘)
        var missing: [String] = []
        if noSpeed == sortedFixes.count { missing.append("速度=") }
        if noCourse == sortedFixes.count { missing.append("course=") }
        print("  判定不能: fix 行に \(missing.joined(separator: " と ")) がありません"
              + "(\(sortedFixes.count) 件すべて)。")
        print("  生の course を復元できないので、学習も検疫も評価できません。")
        print("  これらの列を持つ版でログを取り直してください。")
        print("  **使用可能率も学習の成立時刻も出しません**(0% ではなく、判定できない)。")
        headMountJudged = false
    } else if noSpeed > 0 || noCourse > 0 {
        // 部分的な欠落は「不完全な入力」として明示する。数字は出すが、鵜呑みにさせない
        var missing: [String] = []
        if noSpeed > 0 { missing.append("速度= が \(noSpeed) 件") }
        if noCourse > 0 { missing.append("course= が \(noCourse) 件") }
        print("  ※ 不完全な入力: fix \(sortedFixes.count) 件のうち "
              + "\(missing.joined(separator: " / ")) 欠けています。")
        print("     その区間は course なしとして扱われ、**学習も検疫も進みません**。")
        print("     下の数字は実機と食い違います。**高く出ることも低く出ることもあります** —")
        print("     欠けたのが「合っていた区間」なら低く、「ずれていた区間」なら"
              + "退避を再現できず高く出ます")
    }
    func rawCourse(at t: Date) -> Double? {
        // t 以下で最も新しい fix を二分探索で拾う
        var lo = 0, hi = sortedFixes.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sortedFixes[mid].time <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let f = sortedFixes[found]
        // fix 行に書かれた古さは「書いた時点」のもの。そこからの経過を足す
        let age = (f.ageSec ?? 0) + t.timeIntervalSince(f.time)
        let motion = MotionFix(courseDeg: f.courseDeg, courseAccuracyDeg: f.courseAccuracyDeg,
                               speedMps: f.speedMps, compassHeadingDeg: nil,
                               ageSec: age, horizontalAccuracyM: f.accuracyM)
        // **製品と同じ規則**。保持値もコンパスも渡さない(→ WalkSessionController.rawCourseBearing)
        guard let t = TravelDirection.resolve(motion, held: nil, params: params.location),
              t.source == .course else { return nil }
        return t.deg
    }

    // ログは log_interval_sec(既定 1 秒)に間引かれている。実機は update_hz(既定 10 Hz)。
    // **学習の重みは標本数で数える**ので、間引いたまま流すと立ち上がりが 10 倍遅く見える。
    // 標本を間隔ぶん複製して近似する(下の但し書きのとおり、あくまで近似)
    let subdivisions = max(1, Int((params.headMount.updateHz * params.headMount.logIntervalSec)
                                  .rounded()))
    var fusion = HeadMountFusion()
    let fp = params.headMount.fusion
    let t0 = headSamples[0].time
    var counts: [String: Int] = [:]
    var transitions: [(Double, String)] = []
    var lastLabel: String?
    var firstLearnedAt: Double?
    var firstUsableAt: Double?
    var usableSamples = 0
    var offsetAgreementSum = 0.0
    var offsetAgreementCount = 0

    for (i, s) in headSamples.enumerated() {
        let dt = i + 1 < headSamples.count
            ? headSamples[i + 1].time.timeIntervalSince(s.time) : params.headMount.logIntervalSec
        let step = dt / Double(subdivisions)
        let course = rawCourse(at: s.time)
        var use = HeadMountFusion.Use.noSample
        for k in 0..<subdivisions {
            let t = s.time.timeIntervalSinceReferenceDate + Double(k) * step
            use = fusion.ingest(headingDeg: s.rawDeg, rawCourseDeg: course, at: t, p: fp)
        }
        let elapsed = s.time.timeIntervalSince(t0)
        if firstLearnedAt == nil, fusion.learnedOffsetDeg != nil { firstLearnedAt = elapsed }
        if firstUsableAt == nil, use.isUsable { firstUsableAt = elapsed }
        if use.isUsable { usableSamples += 1 }
        counts[use.label, default: 0] += 1
        if lastLabel != use.label {
            transitions.append((elapsed, use.label))
            lastLabel = use.label
        }
        // 再生で得た学習値が、ログに残っていた値と合っているか(配線の照合)
        if let logged = s.loggedOffsetDeg, let replayed = fusion.learnedOffsetDeg {
            offsetAgreementSum += abs(Geo.angularDiffDeg(logged, replayed))
            offsetAgreementCount += 1
        }
    }

    // **門の強さを振る。** 首を回すと R が落ちて頭方位が使えなくなる循環
    // (2026-09-09 の実測)への対策が効くかを、歩き直さずに見る
    func sweepGate(_ gateDeg: Double) -> (usable: Int, firstUsable: Double?, finalR: Double) {
        var f = HeadMountFusion()
        var p = fp
        p.offset.gateDeg = gateDeg
        var usable = 0
        var firstUsable: Double?
        for (i, s) in headSamples.enumerated() {
            let dt = i + 1 < headSamples.count
                ? headSamples[i + 1].time.timeIntervalSince(s.time)
                : params.headMount.logIntervalSec
            let step = dt / Double(subdivisions)
            let course = rawCourse(at: s.time)
            var use = HeadMountFusion.Use.noSample
            for k in 0..<subdivisions {
                let t = s.time.timeIntervalSinceReferenceDate + Double(k) * step
                use = f.ingest(headingDeg: s.rawDeg, rawCourseDeg: course, at: t, p: p)
            }
            if use.isUsable {
                usable += 1
                if firstUsable == nil { firstUsable = s.time.timeIntervalSince(t0) }
            }
        }
        return (usable, firstUsable, f.concentration)
    }

    print("\n  門(推定から離れた標本を捨てる角度)を振る:")
    print("    門      使用可能        最初に使えた   最終 R")
    for gate in [0.0, 30, 45, 60, 90] {
        let s = sweepGate(gate)
        let pct = 100 * Double(s.usable) / Double(headSamples.count)
        let first = s.firstUsable.map { String(format: "%.0f 秒", $0) } ?? "成立せず"
        print(String(format: "    %3.0f°  %5d 件(%3.0f%%)  %10@  %.2f",
                     gate, s.usable, pct, first as NSString, s.finalR))
    }
    print("    ※ 0° = 門なし(2026-09-09 以前の挙動)")

    func secs(_ v: Double?) -> String { v.map { String(format: "%.0f 秒", $0) } ?? "成立せず" }
    guard headMountJudged else {
        // 必要な列が無い。**数字を出さずに終える**(判定不能と失敗を混ぜない)
        print("  ※ 上記のとおり判定できないため、使用可能率・成立時刻・遷移は出しません。")
        exit(0)
    }
    print("  最初に学習が成立: \(secs(firstLearnedAt))")
    print("  最初に使用可能: \(secs(firstUsableAt))")
    print(String(format: "  使用可能だった割合: %.0f%%(%d / %d 件)",
                 100 * Double(usableSamples) / Double(headSamples.count),
                 usableSamples, headSamples.count))
    print("  内訳:")
    for (label, n) in counts.sorted(by: { $0.value > $1.value }) {
        print(String(format: "    %-10@ %5d 件(%.0f%%)", label as NSString, n,
                     100 * Double(n) / Double(headSamples.count)))
    }
    if let learned = fusion.learnedOffsetDeg {
        print(String(format: "  最終的な学習値: %+.1f°(R=%.2f)", learned, fusion.concentration))
    } else {
        print(String(format: "  最終的な学習値: 成立せず(R=%.2f)", fusion.concentration))
    }
    if offsetAgreementCount > 0 {
        print(String(format: "  ログに残っていた学習値との差(平均): %.1f°(%d 件で照合)",
                     offsetAgreementSum / Double(offsetAgreementCount), offsetAgreementCount))
    }
    print("  遷移(先頭 12 件):")
    for (t, label) in transitions.prefix(12) {
        print(String(format: "    %6.0f 秒  → %@", t, label as NSString))
    }
    if transitions.count > 12 { print("    …ほか \(transitions.count - 12) 回") }

    print("")
    print("  ※ これは**間引いたログからの再評価**であって、実機の完全な再現ではありません。")
    print("     ログは \(params.headMount.logIntervalSec) 秒間隔、実機は "
          + "\(params.headMount.updateHz) Hz。学習の重みは標本を \(subdivisions) 倍に"
          + "複製して近似しています。1 秒未満の磁気の乱れは復元できません。")
    print("     検疫の 5 秒窓や大きな分布の評価には十分ですが、"
          + "offset_min_samples の立ち上がりは近似値として読んでください。")
    print("  ※ 閾値を振り直すには、設定 JSON を書き換えて "
          + "scripts/replay_log.sh <ログ> <設定JSON> を実行してください。")
}
