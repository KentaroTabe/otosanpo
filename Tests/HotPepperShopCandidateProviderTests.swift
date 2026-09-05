import XCTest
@testable import OtoSanpo

final class HotPepperShopCandidateProviderTests: XCTestCase {
    private let origin = GeoPoint(latitude: 35.0, longitude: 137.0)

    override func tearDown() {
        MockURLProtocol.handlers = []
        super.tearDown()
    }

    func testRangeConversionRoundsSearchRadiusUpToHotPepperRange() {
        XCTAssertEqual(HotPepperShopCandidateProvider.hotPepperRange(forSearchRadiusM: 300), 1)
        XCTAssertEqual(HotPepperShopCandidateProvider.hotPepperRange(forSearchRadiusM: 301), 2)
        XCTAssertEqual(HotPepperShopCandidateProvider.hotPepperRange(forSearchRadiusM: 500), 2)
        XCTAssertEqual(HotPepperShopCandidateProvider.hotPepperRange(forSearchRadiusM: 501), 3)
        XCTAssertEqual(HotPepperShopCandidateProvider.hotPepperRange(forSearchRadiusM: 1_001), 4)
        XCTAssertEqual(HotPepperShopCandidateProvider.hotPepperRange(forSearchRadiusM: 2_001), 5)
    }

    func testRequestParametersAndShopMapping() async throws {
        MockURLProtocol.handlers = [
            { request in
                let items = Self.queryItems(request)
                XCTAssertEqual(items["key"], "test-key")
                XCTAssertEqual(items["lat"], "35.0")
                XCTAssertEqual(items["lng"], "137.0")
                XCTAssertEqual(items["range"], "1")
                XCTAssertEqual(items["count"], "100")
                XCTAssertEqual(items["start"], "1")
                XCTAssertEqual(items["format"], "json")
                return Self.response("""
                {
                  "results": {
                    "results_available": 1,
                    "results_returned": 1,
                    "shop": [
                      {
                        "id": "J001",
                        "name": "喫茶おと",
                        "lat": "35.1",
                        "lng": "137.2",
                        "genre": { "name": "カフェ" }
                      }
                    ]
                  }
                }
                """)
            }
        ]
        let provider = HotPepperShopCandidateProvider(apiKey: "test-key",
                                                      session: Self.mockSession())

        let shops = try await provider.shops(near: origin, searchRadiusM: 300)

        XCTAssertEqual(shops, [
            Shop(shopID: "J001", name: "喫茶おと", latitude: 35.1, longitude: 137.2,
                 category: "カフェ")
        ])
    }

    func testPagingUsesResultsAvailable() async throws {
        MockURLProtocol.handlers = [
            { _ in
                Self.response("""
                {
                  "results": {
                    "results_available": 101,
                    "results_returned": 100,
                    "shop": [
                      { "id": "J001", "name": "一", "lat": 35.0, "lng": 137.0,
                        "genre": { "name": "カフェ" } }
                    ]
                  }
                }
                """)
            },
            { request in
                XCTAssertEqual(Self.queryItems(request)["start"], "101")
                return Self.response("""
                {
                  "results": {
                    "results_available": 101,
                    "results_returned": 1,
                    "shop": [
                      { "id": "J002", "name": "二", "lat": 35.1, "lng": 137.1,
                        "genre": { "name": "和食" } }
                    ]
                  }
                }
                """)
            }
        ]
        let provider = HotPepperShopCandidateProvider(apiKey: "test-key",
                                                      session: Self.mockSession())

        let shops = try await provider.shops(near: origin, searchRadiusM: 300)

        XCTAssertEqual(shops.map(\.shopID), ["J001", "J002"])
    }

    func testHTTPErrorIsDistinguished() async {
        MockURLProtocol.handlers = [
            { _ in Self.response("{}", statusCode: 503) }
        ]
        let provider = HotPepperShopCandidateProvider(apiKey: "test-key",
                                                      session: Self.mockSession())

        do {
            _ = try await provider.shops(near: origin, searchRadiusM: 300)
            XCTFail("Expected HTTP error")
        } catch HotPepperShopCandidateProvider.ProviderError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAPIResponseBodyErrorIsDistinguished() async {
        MockURLProtocol.handlers = [
            { _ in
                Self.response("""
                { "results": { "error": [ { "message": "API key is invalid" } ] } }
                """)
            }
        ]
        let provider = HotPepperShopCandidateProvider(apiKey: "test-key",
                                                      session: Self.mockSession())

        do {
            _ = try await provider.shops(near: origin, searchRadiusM: 300)
            XCTFail("Expected API body error")
        } catch HotPepperShopCandidateProvider.ProviderError.apiErrors(let messages) {
            XCTAssertEqual(messages, ["API key is invalid"])
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDecodingErrorIsDistinguished() async {
        MockURLProtocol.handlers = [
            { _ in Self.response("{ \"results\": { \"shop\": [") }
        ]
        let provider = HotPepperShopCandidateProvider(apiKey: "test-key",
                                                      session: Self.mockSession())

        do {
            _ = try await provider.shops(near: origin, searchRadiusM: 300)
            XCTFail("Expected decoding error")
        } catch HotPepperShopCandidateProvider.ProviderError.decoding {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func queryItems(_ request: URLRequest) -> [String: String] {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }

    private static func response(_ body: String, statusCode: Int = 200)
        -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://example.test/")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode,
                                       httpVersion: nil, headerFields: nil)!
        return (response, Data(body.utf8))
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    static var handlers: [Handler] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard !Self.handlers.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let handler = Self.handlers.removeFirst()
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
    }
}
