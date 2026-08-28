import XCTest
@testable import OtoSanpo

/// 波形の合成。**アプリと紹介用の書き出しで同じ音が鳴る**ことが前提なので、
/// ここが変わると両方が同時に変わる。
final class ToneRendererTests: XCTestCase {
    private let tone = AppParameters.ToneSpec(
        freqsHz: [880, 1174.7], blipSec: 0.09, gapSec: 0.06, noiseMix: 0)

    /// 標本数は「ブリップ × 音数 + 間 × (音数 − 1)」
    func testSampleCountFollowsTheToneSpec() {
        let s = ToneRenderer.samples(tone, sampleRate: 44100, gain: 0.5)
        let blip = Int(0.09 * 44100), gap = Int(0.06 * 44100)
        XCTAssertEqual(s.count, blip * 2 + gap)
    }

    /// 端は窓で 0 に落ちる(プチッと鳴らないこと)
    func testEnvelopeStartsAtZero() {
        let s = ToneRenderer.samples(tone, sampleRate: 44100, gain: 1.0)
        XCTAssertEqual(s.first ?? 1, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(s.max() ?? 0, 0.5)
    }

    /// 同じ設定なら毎回同じ音(雑音も再現性がある)
    func testNoiseIsReproducible() {
        var noisy = tone
        noisy.noiseMix = 0.5
        XCTAssertEqual(ToneRenderer.samples(noisy, sampleRate: 22050, gain: 1),
                       ToneRenderer.samples(noisy, sampleRate: 22050, gain: 1))
    }

    func testDarkenLowersTheFrequenciesAndRemovesNoise() {
        var noisy = tone
        noisy.noiseMix = 0.4
        let dark = ToneRenderer.darken(noisy, by: 1.0)
        XCTAssertEqual(dark.freqsHz[0], 440, accuracy: 1e-9)
        XCTAssertEqual(dark.noiseMix, 0, accuracy: 1e-9)
    }

    // MARK: - 先頭の無音(定位が滲むのを防ぐ)

    /// **定位は鳴り始めてから目標へ移る。** 無音のうちに移し終えれば、
    /// 音が出るときにはもう目標の向きになっている(2026-08-25 の「鳴り出しは右、
    /// なり終わりは左」への対処)
    func testLeadSilenceIsPrependedWithoutTouchingTheTone() {
        let base = ToneRenderer.samples(tone, sampleRate: 44100, gain: 1)
        let led = ToneRenderer.withLeadSilence(base, seconds: 0.06, sampleRate: 44100)
        let frames = Int(0.06 * 44100)
        XCTAssertEqual(led.count, base.count + frames)
        XCTAssertTrue(led.prefix(frames).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(led.suffix(base.count)), base)
    }

    /// 0 なら何も足さない(設定で無効にできる)
    func testZeroLeadSilenceChangesNothing() {
        let base = ToneRenderer.samples(tone, sampleRate: 44100, gain: 1)
        XCTAssertEqual(ToneRenderer.withLeadSilence(base, seconds: 0, sampleRate: 44100), base)
        XCTAssertEqual(ToneRenderer.withLeadSilence(base, seconds: -1, sampleRate: 44100), base)
    }

    /// 空の音には足さない(足すと「無音だけの音」が鳴ることになる)
    func testEmptyToneStaysEmpty() {
        XCTAssertTrue(ToneRenderer.withLeadSilence([], seconds: 0.06, sampleRate: 44100).isEmpty)
    }
}
