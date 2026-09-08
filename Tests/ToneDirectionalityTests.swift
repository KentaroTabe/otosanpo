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
    /// **配る値は 5 つとも揃っていること**を要求する(片方だけ変えると機種差になる)。
    /// 実験ビルドで変えるのは**方向を担う 2 種だけ**で、それは `head_mount.enabled` の
    /// 側で切り替わる(2026-09-08 合議)。この検査が見ているのは配布値の側。
    /// 値を上げて配ると決めた時は、この検査の期待値も一緒に更新する
    private func shippedConfig() throws -> AppParameters {
        try ConfigLoader.load(from: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/parameters.json"))
    }

    func testShippedTonesAreUniformSoPlatformsMatch() throws {
        let p = try shippedConfig()
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

    /// **実験のスイッチはコミットされた設定で切れていること**(2026-09-08)。
    ///
    /// 倍音とアタックは「散歩の前提条件」に昇格したが、**実験ビルドだけ**に載せる
    /// (利用者判断)。スイッチは `head_mount.enabled` ただ 1 つで、
    /// これが false なら音も挙動も配布版とまったく同じになる。
    ///
    /// 前回は判断待ちの値が Android の APK にだけ焼き込まれて配布版と違う音になった。
    /// **その経路をここで塞ぐ** — 実験のために true にしたまま
    /// コミットすれば、この検査が落ちる
    func testTheExperimentSwitchIsOffInTheShippedConfig() throws {
        let p = try shippedConfig()
        XCTAssertFalse(p.headMount.enabled,
                       "実験のスイッチを true のままコミットしてはいけない"
                       + "(有効性パルスと実験用の音色が配布物に載る)")
    }

    /// 実験用の音色は**方向を担う音にだけ**載る。
    /// 周波数・長さ・間隔は元のまま(音の意味を変えず、手がかりだけ足す)
    func testExperimentToneOverlayKeepsThePitchAndOnlyChangesTheCues() throws {
        let p = try shippedConfig()
        let base = p.audio.tones.homeBeacon
        let rich = p.experiment.applied(to: base)
        XCTAssertEqual(rich.freqsHz, base.freqsHz, "音程は変えない")
        XCTAssertEqual(rich.blipSec, base.blipSec, accuracy: 1e-9, "長さは変えない")
        XCTAssertEqual(rich.gapSec, base.gapSec, accuracy: 1e-9, "間隔は変えない")
        XCTAssertEqual(rich.harmonics, p.experiment.directionalHarmonics)
        XCTAssertEqual(rich.attackRatio, p.experiment.directionalAttackRatio, accuracy: 1e-9)
        XCTAssertGreaterThan(rich.harmonics, base.harmonics,
                             "実験の値は配布版より倍音が多いはず(そうでなければ実験にならない)")
        XCTAssertLessThan(rich.attackRatio, base.attackRatio,
                          "実験の値は配布版より立ち上がりが鋭いはず")
    }

    /// **方向を持たない 3 種には実験の値を載せない**(2026-09-08 合議)。
    /// 無関係な音色変更が実験に混ざると、何を聴いているのか分からなくなる
    func testExperimentOverlayIsNotAppliedToTheNonDirectionalTones() throws {
        let p = try shippedConfig()
        // 実験ビルドで差し替えるのは suggestion と home_beacon だけ。
        // ここでは「上書きすると別物になる」ことを示し、
        // 実際に上書きされる対象が 2 種であることは EarconSynth 側の責務として分ける
        for (name, tone) in [("時間到来", p.audio.tones.timeUpPrompt),
                             ("確認音", p.audio.tones.returnAck),
                             ("到着音", p.audio.tones.arrival)] {
            let overlaid = p.experiment.applied(to: tone)
            XCTAssertNotEqual(overlaid.harmonics, tone.harmonics,
                              "\(name): 上書きすれば変わる値であることの確認"
                              + "(この 3 種には上書きを適用しない、が設計)")
        }
    }

    /// 上書きした音が**実際に高域を持つ**ことまで確かめる。
    /// 設定値を読み替えただけで、音が変わっていなければ意味が無い
    func testExperimentToneActuallyProducesTheILDBand() throws {
        let p = try shippedConfig()
        let sr = 44100.0
        let plain = ToneRenderer.samples(p.audio.tones.homeBeacon, sampleRate: sr, gain: 1)
        let rich = ToneRenderer.samples(p.experiment.applied(to: p.audio.tones.homeBeacon),
                                        sampleRate: sr, gain: 1)
        XCTAssertLessThan(highBandRatio(plain, sampleRate: sr, above: 1500), 0.05,
                          "配布版のビーコンは純音で高域を持たない")
        XCTAssertGreaterThan(highBandRatio(rich, sampleRate: sr, above: 1500), 0.08,
                             "実験用の値で 1.5kHz 超の成分が出ていない")
    }
}
