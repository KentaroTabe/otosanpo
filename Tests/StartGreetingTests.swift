import XCTest
@testable import OtoSanpo

/// 散歩を始めるときの一言。**境界の扱い**(開始を含み終了を含まない)と、
/// **真夜中をまたぐ窓**が要点。文言は `config/parameters.json` にある。
final class StartGreetingTests: XCTestCase {
    /// 設定ファイルと同じ内容。ここを直すときは parameters.json も直す
    private let windows = [
        AppParameters.GreetingWindow(fromHour: 22, toHour: 5,
                                     message: "深夜の散歩は是非背後にお気をつけて"),
        AppParameters.GreetingWindow(fromHour: 5, toHour: 7,
                                     message: "早起きは三文の得"),
        AppParameters.GreetingWindow(fromHour: 7, toHour: 22,
                                     message: "さぁ歩き始めましょう"),
    ]

    /// **真夜中をまたぐ窓。** 22 時から翌 5 時まで同じ文言になる
    func testLateNightWrapsAcrossMidnight() {
        for h in [22, 23, 0, 3, 4] {
            XCTAssertEqual(StartGreeting.message(hour: h, windows: windows),
                           "深夜の散歩は是非背後にお気をつけて", "hour=\(h)")
        }
    }

    func testEarlyMorning() {
        for h in [5, 6] {
            XCTAssertEqual(StartGreeting.message(hour: h, windows: windows),
                           "早起きは三文の得", "hour=\(h)")
        }
    }

    func testDayTime() {
        for h in [7, 12, 18, 21] {
            XCTAssertEqual(StartGreeting.message(hour: h, windows: windows),
                           "さぁ歩き始めましょう", "hour=\(h)")
        }
    }

    /// **境界は開始を含み、終了を含まない。** 5 時ちょうどは早朝、7 時ちょうどは日中
    func testBoundariesBelongToTheWindowThatStartsThere() {
        XCTAssertEqual(StartGreeting.message(hour: 5, windows: windows), "早起きは三文の得")
        XCTAssertEqual(StartGreeting.message(hour: 7, windows: windows), "さぁ歩き始めましょう")
        XCTAssertEqual(StartGreeting.message(hour: 22, windows: windows),
                       "深夜の散歩は是非背後にお気をつけて")
    }

    /// 24 時間すべてに何かしら当たる(黙る時間帯を作らない)
    func testEveryHourHasAMessage() {
        for h in 0...23 {
            XCTAssertNotNil(StartGreeting.message(hour: h, windows: windows), "hour=\(h)")
        }
    }

    func testOutOfRangeHoursProduceNothing() {
        XCTAssertNil(StartGreeting.message(hour: -1, windows: windows))
        XCTAssertNil(StartGreeting.message(hour: 24, windows: windows))
    }

    /// 窓が無ければ黙る(設定で空にできる)
    func testNoWindowsMeansNoMessage() {
        XCTAssertNil(StartGreeting.message(hour: 12, windows: []))
    }

    /// 時計から読む経路も同じ答えになる
    func testReadsTheHourFromADate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 25
        components.hour = 23
        let date = calendar.date(from: components)!
        XCTAssertEqual(StartGreeting.message(at: date, calendar: calendar, windows: windows),
                       "深夜の散歩は是非背後にお気をつけて")
    }
}
