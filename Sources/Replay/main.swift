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

guard let first = returning.first, let last = returning.last, returning.count > 2 else {
    print("帰路の fix が足りません(迂回率は帰路でしか意味を持ちません)")
    exit(0)
}

// 自宅座標はログに無いため、到着地点(最後の fix)を自宅とみなす。
// 到着判定は arrival_radius_m 以内で成立しているので、その誤差の範囲で近似できる
let straight = Geo.distanceM(first.point, last.point)
let elapsedMin = last.time.timeIntervalSince(first.time) / 60
print(String(format: "帰路: 直線=%.0fm 所要=%.1f分 (自宅は到着地点で近似)", straight, elapsedMin))

let b = params.budget
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
