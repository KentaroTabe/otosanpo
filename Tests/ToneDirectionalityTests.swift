import XCTest
@testable import OtoSanpo

/// 左右の定位を可能にする音の性質(倍音とアタック)。
///
/// ## なぜ要るか(2026-09-01)
///
/// 頭部固定の実験で、**誘導音 271 発のうち 61% が 30° を超えて振れていたのに
/// 「音の向きが分からず従えなかった」**(提案 5 件中 1 件しか曲がれず)。
/// 定位の計算ではなく**音の素材**が原因だった。
///
/// - 440 Hz の純音は波長 78 cm で頭(約 18 cm)を回折し、**両耳間レベル差(ILD)が出ない**。
///   ILD が効くのは概ね 1.5 kHz 以上
/// - 左右対称の Hann 窓は立ち上がりが緩く、**両耳間時間差(ITD)の手がかりも弱い**。
///   持続する純音の位相差は周期的で曖昧なので、頼れるのは「どちらの耳に先に届いたか」
///
/// つまり手がかりを 2 つとも欠いていた。倍音で高域成分を、鋭いアタックで onset を作る。
final class ToneDirectionalityTests: XCTestCase {

    private func spec(harmonics: Int, attack: Double,
                      decay: Double = 0.7) -> AppParameters.ToneSpec {
        AppParameters.ToneSpec(freqsHz: [440], blipSec: 0.07, gapSec: 0,
                               noiseMix: 0, harmonics: harmonics,
                               harmonicDecay: decay, attackRatio: attack)
    }

    /// 指定周波数より上の帯域が持つ**振幅**の割合(素朴な DFT)。
    ///
    /// パワー比ではなく振幅比で見る。聴覚は対数的で、パワー比 0.3%(−25 dB)でも
    /// 振幅比では 5% あり手がかりとして働くため、**パワー比だと厳しすぎて
    /// 「聞こえているのに落ちる」検査になる**
    private func highBandRatio(_ s: [Float], sampleRate: Double, above: Double) -> Double {
        var total = 0.0, high = 0.0
        // 50 Hz 刻みで 6 kHz まで見る(基音 440 とその倍音を取りこぼさない粒度)
        for k in stride(from: 50.0, through: 6000.0, by: 50.0) {
            var re = 0.0, im = 0.0
            for (i, v) in s.enumerated() {
                let a = 2 * Double.pi * k * Double(i) / sampleRate
                re += Double(v) * cos(a)
                im += Double(v) * sin(a)
            }
            let amplitude = (re * re + im * im).squareRoot()
            total += amplitude
            if k > above { high += amplitude }
        }
        return total > 0 ? high / total : 0
    }

    /// **倍音が ILD の効く帯域(1.5 kHz 超)にエネルギーを作る。**
    /// これが無いと、どれだけ HRTF が正確でも左右は聴き分けられない
    func testHarmonicsCreateEnergyAboveTheILDThreshold() {
        let sr = 44100.0
        let pure = ToneRenderer.samples(spec(harmonics: 1, attack: 0.5), sampleRate: sr, gain: 1)
        let rich = ToneRenderer.samples(spec(harmonics: 4, attack: 0.5), sampleRate: sr, gain: 1)

        let pureHigh = highBandRatio(pure, sampleRate: sr, above: 1500)
        let richHigh = highBandRatio(rich, sampleRate: sr, above: 1500)

        // 減衰 0.7・4 倍音なら、1760 Hz の正規化振幅は約 13%(−17 dB)。
        // 窓の広がりで隣接ビンへ漏れるぶんを見て 8% を下限に置く
        XCTAssertLessThan(pureHigh, 0.05, "440Hz の純音に高域があってはいけない")
        XCTAssertGreaterThan(richHigh, 0.08, "倍音が 1.5kHz 超の成分を作れていない")
    }

    /// 倍音を足しても音量(尖頭値)は跳ね上がらない。重みの合計で正規化しているため
    func testHarmonicsDoNotInflateLoudness() {
        let sr = 44100.0
        let pure = ToneRenderer.samples(spec(harmonics: 1, attack: 0.5), sampleRate: sr, gain: 1)
        let rich = ToneRenderer.samples(spec(harmonics: 4, attack: 0.5), sampleRate: sr, gain: 1)
        let pureMax = pure.map { abs($0) }.max() ?? 0
        let richMax = rich.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(richMax, pureMax * 1.3, "倍音で音量が跳ねている")
    }

    /// **鋭いアタックは立ち上がりを速くする**(ITD の手がかり)。
    /// 尖頭に達するまでの標本数で測る
    func testSharpAttackReachesPeakSooner() {
        let sr = 44100.0
        func framesToPeak(_ attack: Double) -> Int {
            let s = ToneRenderer.samples(spec(harmonics: 1, attack: attack), sampleRate: sr, gain: 1)
            let peak = s.map { abs($0) }.max() ?? 0
            return s.firstIndex { abs($0) >= peak * 0.9 } ?? s.count
        }
        let symmetric = framesToPeak(0.5)   // 従来の Hann 窓
        let sharp = framesToPeak(0.05)
        XCTAssertLessThan(sharp, symmetric / 4, "アタックが鋭くなっていない")
    }

    /// 鋭くしても**先頭は 0 から始まる**(プチッと鳴らない)
    func testSharpAttackStillStartsFromSilence() {
        let s = ToneRenderer.samples(spec(harmonics: 4, attack: 0.05), sampleRate: 44100, gain: 1)
        XCTAssertEqual(s.first ?? 1, 0, accuracy: 1e-6)
        XCTAssertEqual(s.last ?? 1, 0, accuracy: 1e-3, "終端も 0 へ落ちること")
    }

    /// harmonics 1・attackRatio 0.5 は**従来の音と同じ**(A/B で戻せる)
    func testLegacyValuesReproduceTheOldTone() {
        let s = ToneRenderer.samples(spec(harmonics: 1, attack: 0.5), sampleRate: 44100, gain: 1)
        // 従来の Hann 窓は中央で尖頭に達する
        let peak = s.map { abs($0) }.max() ?? 0
        let peakIndex = s.firstIndex { abs($0) >= peak * 0.99 } ?? 0
        XCTAssertEqual(Double(peakIndex) / Double(s.count), 0.5, accuracy: 0.1)
    }

    /// **配る設定は 5 つの音すべてで揃っていること**(2026-09-02 利用者判断)。
    ///
    /// > 配布しているバージョンが機種によって違うという状況はあるべきではない
    ///
    /// 倍音とアタックは**効果が未確認のまま Android の APK にだけ入り**、
    /// iOS のテスターとは違う音が鳴る状態になっていた。仕組みは残し、
    /// 配る値は配布版(testflight-202608311200)と同じ純音に戻した。
    ///
    /// ここが守るのは「実験の値がうっかり配布物へ混ざらないこと」。
    /// **実験するときは 5 つとも変える**(片方だけ変えると機種差になる)。
    /// 値を上げて配ると決めた時は、この検査の期待値も一緒に更新する
    func testShippedTonesAreUniformSoPlatformsMatch() throws {
        let p = try ConfigLoader.load(from: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/parameters.json"))
        let tones = [("提案音", p.audio.tones.suggestion),
                     ("時間到来", p.audio.tones.timeUpPrompt),
                     ("確認音", p.audio.tones.returnAck),
                     ("ビーコン", p.audio.tones.homeBeacon),
                     ("到着音", p.audio.tones.arrival)]
        for (name, tone) in tones {
            XCTAssertEqual(tone.harmonics, 1, "\(name): 配る値は配布版と同じ純音のはず")
            XCTAssertEqual(tone.attackRatio, 0.5, accuracy: 1e-9,
                           "\(name): 配る値は配布版と同じ左右対称の窓のはず")
        }
    }
}
