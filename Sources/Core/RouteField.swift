import Foundation

/// **自宅までの経路を、地図全体にあらかじめ配っておく**構造。
///
/// なぜ「経路」ではなく「場」なのか:
/// 帰宅推定は散策中も毎回の位置更新で要る(帰りどきの判定)。そのたびに経路を引き直すのは
/// 重いし、利用者が経路から外れるたびに引き直す設計は「叱らない」原則と相性が悪い。
/// **終点が自宅で固定**なので、自宅から全節点への最短経路を 1 回だけ解いておけば、
/// どこに居ても「ここから何 m か」「次にどちらへ行くか」が引くだけで分かる。
/// 逸脱しても再計算は要らない — 逸脱先の節点も既に答えを持っている。
///
/// 距離を 2 本持つ理由:
/// - `cost`: 経路の**選び方**に使う重み付き距離(横断と道の種別を嫌う)
/// - `metres`: 帰宅**時間の見積もり**に使う実距離。重みを掛けた値で割ると時間にならない
///
/// 構築は数万節点の探索になるため**背景で行う**(`Sendable`)。できるまでは
/// 呼び出し側が直線距離で代替する。
public struct RouteField: Sendable {
    /// 経路の選び方。分岐提案と同じ価値観を使い、好みを一箇所に保つ
    public struct Weights: Equatable, Sendable {
        public let crossCostWeight: Double
        public let wayClassWeight: Double

        public init(crossCostWeight: Double, wayClassWeight: Double) {
            self.crossCostWeight = crossCostWeight
            self.wayClassWeight = wayClassWeight
        }
    }

    public let goal: GeoPoint
    /// 節点 → 自宅までの**重み付き**距離。経路の選び方(どちらへ進むか)はこれで決める
    private let cost: [Double]
    /// 節点 → 自宅までの実距離 [m]。時間の見積もりはこれで行う。到達できない節点は `.infinity`
    private let metres: [Double]
    /// 節点 → 自宅へ向かう次の節点。-1 は「次が無い(自宅そのものか到達不能)」
    private let next: [Int]
    private let snapMaxDistanceM: Double

    /// 自宅へ到達できる節点の数(地図が繋がっているかの確認用)
    public let reachableNodes: Int

    /// 自宅から全節点への最短経路木を 1 回だけ解く。
    /// 5 km 圏で数万節点になるので、計算はセッション開始時の 1 回に限る。
    public init?(graph: WalkGraph, goal: GeoPoint, snapMaxDistanceM: Double, weights: Weights) {
        guard let goalNode = graph.nearestNode(to: goal, maxDistanceM: snapMaxDistanceM) else {
            return nil
        }
        self.goal = goal
        self.snapMaxDistanceM = snapMaxDistanceM

        let count = graph.map.nodes.count
        // **存在しない節点を指す道は捨てる。** ここは生の添字で配列を引くので、
        // 拒まないと壊れた地図で落ちる(読み込み側の検分 WalkMap.integrityIssue と
        // 二重の守り。タイル結合など検分を通らない経路もここを通るため)
        func indicesValid(_ way: WalkMap.Way) -> Bool {
            way.n.allSatisfy { $0 >= 0 && $0 < count }
        }
        // **隣接を平坦な配列に前計算する。** 辞書引きと配列の作り直しを探索の内側から追い出す。
        // 実機は Debug ビルドで動かすため、内側のループの割り当ては素直に効く
        // (前計算なしでは Mac・Debug で 1.3 秒かかっていた)
        var degree = [Int](repeating: 0, count: count)
        for way in graph.map.ways where way.n.count >= 2 && indicesValid(way) {
            for i in 0..<(way.n.count - 1) {
                degree[way.n[i]] += 1
                degree[way.n[i + 1]] += 1
            }
        }
        var start = [Int](repeating: 0, count: count + 1)
        for i in 0..<count { start[i + 1] = start[i] + degree[i] }
        let edgeCount = start[count]
        var to = [Int](repeating: 0, count: edgeCount)
        var length = [Double](repeating: 0, count: edgeCount)
        var weighted = [Double](repeating: 0, count: edgeCount)
        var fill = start
        for way in graph.map.ways where way.n.count >= 2 && indicesValid(way) {
            // 横断と道の種別は「その道を通る負担」として距離を割り増しする。
            // 分岐提案では score から引いていたが、経路長では掛けるのが素直
            let penalty = 1
                + Double(way.cross) * weights.crossCostWeight
                + Double(way.cls.preferenceRank) * weights.wayClassWeight
            for i in 0..<(way.n.count - 1) {
                let a = way.n[i], b = way.n[i + 1]
                guard let pa = graph.map.point(a), let pb = graph.map.point(b) else { continue }
                let d = Geo.distanceM(pa, pb)
                to[fill[a]] = b; length[fill[a]] = d; weighted[fill[a]] = d * penalty
                fill[a] += 1
                to[fill[b]] = a; length[fill[b]] = d; weighted[fill[b]] = d * penalty
                fill[b] += 1
            }
        }

        var cost = [Double](repeating: .infinity, count: count)
        var metres = [Double](repeating: .infinity, count: count)
        var next = [Int](repeating: -1, count: count)
        var done = [Bool](repeating: false, count: count)

        cost[goalNode] = 0
        metres[goalNode] = 0
        var heap = MinHeap()
        heap.push(node: goalNode, priority: 0)

        while let top = heap.pop() {
            let u = top.node
            if done[u] { continue }
            done[u] = true

            for e in start[u]..<start[u + 1] {
                let v = to[e]
                guard !done[v] else { continue }
                let c = cost[u] + weighted[e]
                guard c < cost[v] else { continue }
                cost[v] = c
                metres[v] = metres[u] + length[e]
                // v から見れば、自宅へ向かう次の一歩は u
                next[v] = u
                heap.push(node: v, priority: c)
            }
        }

        self.cost = cost
        self.metres = metres
        self.next = next
        self.reachableNodes = metres.reduce(0) { $0 + ($1.isFinite ? 1 : 0) }
    }

    /// いま乗っている線分の端点のうち、**そこを通ると自宅までが最短になるほう**。
    ///
    /// 幾何的に最寄りの端点を使ってはいけない。線分の手前寄りに居れば最寄りは
    /// **背後の端点**になり、そこを指すと「戻れ」と言うことになる。
    /// 「そこまで歩く距離 + そこから自宅までのコスト」で選べば、実際に通る側が出る。
    ///
    /// **実距離ではなく重み付きコストで比べる。** 経路そのものは重みで選んでいるので、
    /// 実距離で比べると Dijkstra の選択と食い違い、長さが同じ別の道へ入り込む。
    private func forwardNode(from p: GeoPoint, graph: WalkGraph) -> Int? {
        guard let s = graph.snap(p, maxDistanceM: snapMaxDistanceM) else { return nil }
        let way = graph.map.ways[s.wayIndex]
        var best: (node: Int, total: Double)?
        for n in [way.n[s.segmentIndex], way.n[s.segmentIndex + 1]] {
            guard cost.indices.contains(n), cost[n].isFinite,
                  let q = graph.map.point(n) else { continue }
            let total = Geo.distanceM(p, q) + cost[n]
            if best == nil || total < best!.total { best = (n, total) }
        }
        return best?.node
    }

    /// 現在地から自宅までの**実際に歩く距離** [m]。道に乗らない場所では nil。
    /// 直線距離 × 迂回率の推測と違い、川や私有地を突っ切らない。
    public func pathLengthM(from p: GeoPoint, graph: WalkGraph) -> Double? {
        guard let node = forwardNode(from: p, graph: graph),
              let np = graph.map.point(node) else { return nil }
        return Geo.distanceM(p, np) + metres[node]
    }

    /// **いま進むべき向き**(経路の次の一歩の方位)。
    ///
    /// ビーコンはこれを指す。自宅を直線で指すと、川や街区や私有地の向こうを指しうる
    /// (2026-08-19 実測で帰路に 1 回)。**道の上を指していれば「音の鳴る方に歩く」が成り立つ。**
    /// 曲がり角の誘導が受け持つのは角の手前だけなので、その間を埋めるのはこちら。
    ///
    /// - Parameter nodeToleranceM: この距離まで近づいた節点は「着いた」とみなし、
    ///   その先を指す。真上に立つと方位が暴れるため
    public func nextBearingDeg(from p: GeoPoint, graph: WalkGraph,
                               nodeToleranceM: Double) -> Double? {
        guard let node = forwardNode(from: p, graph: graph),
              let here = graph.map.point(node) else { return nil }
        // まだ手前の節点に着いていなければ、まずそこへ向かう。
        // 目の前の節点を飛ばして次を指すと、曲がる前に曲がった先を指すことになる
        if Geo.distanceM(p, here) > nodeToleranceM {
            return Geo.bearingDeg(from: p, to: here)
        }
        guard next[node] >= 0, let np = graph.map.point(next[node]) else {
            // 自宅そのもの(次が無い)。自宅を直接指す
            return Geo.bearingDeg(from: p, to: goal)
        }
        return Geo.bearingDeg(from: here, to: np)
    }

    /// 経路上で**次に曲がる地点**と、そこで踏み出す向き。
    /// 曲がり角の誘導(TurnGuidance)にそのまま渡せる形で返す。
    ///
    /// 直進が続く間は辿り続け、向きが `straightWithinDeg` を超えて変わる節点を「角」とする。
    /// `maxLookM` まで探して見つからなければ nil(まだ曲がる場所は無い)。
    public func nextTurn(from p: GeoPoint, graph: WalkGraph,
                        straightWithinDeg: Double, maxLookM: Double,
                        nodeToleranceM: Double)
        -> (corner: GeoPoint, branchBearingDeg: Double, distanceM: Double)? {
        // 幾何的な最寄りではなく**経路上で先にある端点**から辿る。
        // 背後の節点から始めると、来た道を 1 歩戻ってから数えることになる
        guard let start = forwardNode(from: p, graph: graph) else { return nil }

        var current = start
        guard var here = graph.map.point(start) else { return nil }
        var travelled = Geo.distanceM(p, here)
        // **最初の節点そのものが角**でありうるので、そこへ向かう向きを入りの向きとする。
        // ただし節点が目の前(数 m)なら、その向きは雑音でしかないので使わない
        var incoming: Double? = travelled >= nodeToleranceM
            ? Geo.bearingDeg(from: p, to: here) : nil

        while travelled <= maxLookM {
            let n = next[current]
            guard n >= 0, let np = graph.map.point(n) else { return nil }
            let outgoing = Geo.bearingDeg(from: here, to: np)
            if let inbound = incoming,
               abs(Geo.angularDiffDeg(outgoing, inbound)) > straightWithinDeg {
                // `here`(= current)が角。そこから踏み出す向きが outgoing
                return (corner: here, branchBearingDeg: outgoing, distanceM: travelled)
            }
            travelled += Geo.distanceM(here, np)
            incoming = outgoing
            current = n
            here = np
        }
        return nil
    }
}

/// 経路探索用の最小ヒープ。Swift の標準ライブラリに優先度付きキューが無いため持つ。
/// 距離が縮んだ節点は再度積む(古い項目は `done` で弾く)ので、削除操作は要らない。
struct MinHeap {
    private var items: [(node: Int, priority: Double)] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func push(node: Int, priority: Double) {
        items.append((node, priority))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i].priority < items[parent].priority else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (node: Int, priority: Double)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        items[0] = items[items.count - 1]
        items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = 2 * i + 2
            var smallest = i
            if l < items.count, items[l].priority < items[smallest].priority { smallest = l }
            if r < items.count, items[r].priority < items[smallest].priority { smallest = r }
            guard smallest != i else { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return top
    }
}
