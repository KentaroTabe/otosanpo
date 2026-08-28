import XCTest
@testable import OtoSanpo

final class PromptDeliveryTests: XCTestCase {

    /// AirPods を着けて歩いている人。そのまま鳴らす
    func testPlaysWhileWearing() {
        XCTAssertFalse(PromptDelivery.shouldHold(connected: true, hasEverConnected: true))
    }

    /// 会話などで一時的に外している人。付け直した時に鳴らし直すため保留する
    func testHoldsWhileRemoved() {
        XCTAssertTrue(PromptDelivery.shouldHold(connected: false, hasEverConnected: true))
    }

    /// **AirPods を持っていない人。保留してはいけない。**
    /// 付け直しが起きないので、保留すると時間到来が伝わらないまま終わる
    func testPlaysForTesterWithoutAirPods() {
        XCTAssertFalse(PromptDelivery.shouldHold(connected: false, hasEverConnected: false))
    }

    /// 繋がっている以上、過去の状態に関わらず鳴らす
    func testPlaysOnFirstConnection() {
        XCTAssertFalse(PromptDelivery.shouldHold(connected: true, hasEverConnected: false))
    }
}
