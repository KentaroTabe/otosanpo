import XCTest
@testable import OtoSanpo

/// **配布物に混ぜてはいけないものの番人。**
///
/// なぜ要るか(2026-09-17 利用者依頼): Hot Pepper の API キーを 1 つ作り、
/// テスター全員がそれを使う形にする。キーは `Support/Signing.xcconfig`(.gitignore 済み)に
/// だけ置き、**リポジトリには絶対に載せない**。
/// 載ってしまう経路は決まっているので、そこを塞ぐ:
///
/// - `Support/Info.plist` / `project.yml` に実キーを直接書く
/// - `.gitignore` から `Support/Signing.xcconfig` の行が消える
///
/// ビルドすると実キーはアプリの Info.plist に入る(= 配布物から取り出せる)。
/// これは避けられないので、**使い捨ての口座で作る**という運用で受け止める。
/// 漏れたら作り直せばよい。
final class DistributionHygieneTests: XCTestCase {

    private func repositoryFile(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)   // Tests/DistributionHygieneTests.swift
            .deletingLastPathComponent()             // Tests/
            .deletingLastPathComponent()             // リポジトリの根
            .appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "見つかりません: \(url.path)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 実キーではなく**差し込みの記号**が書かれていること。
    /// ビルド設定(`HOTPEPPER_API_KEY`)から値が入る形を崩さない
    func testTheApiKeyStaysAPlaceholderInTheRepository() throws {
        let plist = try repositoryFile("Support/Info.plist")
        XCTAssertTrue(plist.contains("<key>HotPepperAPIKey</key>"),
                      "Info.plist にキーの項目が無い(取り込み口が消えている)")
        XCTAssertTrue(plist.contains("<string>$(HOTPEPPER_API_KEY)</string>"),
                      "Info.plist に実キーが書かれている可能性がある")
        let project = try repositoryFile("project.yml")
        XCTAssertTrue(project.contains("HotPepperAPIKey: $(HOTPEPPER_API_KEY)"),
                      "project.yml に実キーが書かれている可能性がある")
    }

    /// 手本の設定ファイルは**空のまま**(ここに書くと即コミットされる)
    func testTheExampleSigningFileHasNoKey() throws {
        let example = try repositoryFile("Support/Signing.example.xcconfig")
        guard let line = example.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("HOTPEPPER_API_KEY") }) else {
            return XCTFail("手本に HOTPEPPER_API_KEY の行が無い(置き場所が伝わらない)")
        }
        let value = line.split(separator: "=", maxSplits: 1).count > 1
            ? line.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            : ""
        XCTAssertTrue(value.isEmpty, "手本に値が書かれている: \(line)")
    }

    /// 実キーを置くファイルが git の対象外であること
    func testTheRealSigningFileIsIgnored() throws {
        let ignore = try repositoryFile(".gitignore")
        XCTAssertTrue(ignore.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "Support/Signing.xcconfig" },
                      ".gitignore から Support/Signing.xcconfig の行が消えている")
    }

    /// **提供元の表示を消さない。** 規約が「リクルートより提供されたものである旨を表示する」ことを
    /// 求めている(2026-09-17 確認)。店名を出す画面はこの文言を共有して使う
    func testTheShopCreditNamesTheProvider() {
        XCTAssertTrue(ShopCreditLabel.text.contains("ホットペッパー"),
                      "提供元の表示が変わっている: \(ShopCreditLabel.text)")
    }

    /// **個人化 HRTF の権利情報があること**(2026-09-18 利用者依頼)。
    ///
    /// これがあると、利用者が設定で作った「個人用の空間オーディオ」の形が
    /// `AVAudioEngine` の定位に自動で反映される(Apple の資料)。コードの呼び出しは無いので、
    /// **消えても音が鳴らなくなるわけではなく、黙って汎用 HRTF に戻る。** だから検査で押さえる。
    ///
    /// **AirPods のヘッドトラッキングの権利情報は入れない。**
    /// この装置は頭の向きをスマホ(CMMotionManager)から取っているので、
    /// AirPods 側でも回すと**二重に回る**
    func testTheSpatialAudioProfileEntitlementIsPresentAndHeadTrackingIsNot() throws {
        let plist = try repositoryFile("Support/OtoSanpo.entitlements")
        XCTAssertTrue(plist.contains("<key>com.apple.developer.spatial-audio.profile-access</key>"),
                      "個人化 HRTF の権利情報が消えている")
        XCTAssertFalse(plist.contains("head-pose"),
                       "AirPods のヘッドトラッキングが入っている(頭の向きが二重に回る)")

        // project.yml は生成元。**鍵の行として**書かれているかだけを見る
        // (コメントで名前に触れているのは構わない。採らない理由をそこに書いてある)
        let project = try repositoryFile("project.yml")
        let keyLines = project.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        XCTAssertTrue(keyLines.contains { $0.hasPrefix("com.apple.developer.spatial-audio.profile-access:") },
                      "project.yml から個人化 HRTF の権利情報が消えている")
        XCTAssertFalse(keyLines.contains { $0.hasPrefix("com.apple.developer.coremotion.head-pose:") },
                       "project.yml で AirPods のヘッドトラッキングを有効にしている")
    }
}
