import Foundation

struct HotPepperShopCandidateProvider: ShopCandidateProviding {
    enum ProviderError: Error, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case decoding(String)
        case apiErrors([String])
    }

    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let pageSize = 100

    init(apiKey: String,
         session: URLSession = .shared,
         endpoint: URL = URL(string: "https://webservice.recruit.co.jp/hotpepper/gourmet/v1/")!) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    func shops(near position: GeoPoint, searchRadiusM: Double) async throws -> [Shop] {
        let range = Self.hotPepperRange(forSearchRadiusM: searchRadiusM)
        var start = 1
        var available = Int.max
        var shops: [Shop] = []

        while start <= available {
            let page = try await fetchPage(near: position, range: range, start: start)
            available = page.available
            shops.append(contentsOf: page.shops)
            guard page.returned > 0 else { break }
            start += page.returned
        }

        return shops
    }

    func shops(along route: [GeoPoint], searchRadiusM: Double) async throws -> [Shop] {
        var byID: [String: Shop] = [:]
        for point in sampledPoints(along: route, searchRadiusM: searchRadiusM) {
            for shop in try await shops(near: point, searchRadiusM: searchRadiusM) {
                byID[shop.shopID] = shop
            }
        }
        return Array(byID.values)
    }

    static func configuredOrEmpty(bundle: Bundle = .main,
                                  session: URLSession = .shared) -> ShopCandidateProviding {
        guard let apiKey = apiKey(from: bundle) else { return EmptyShopCandidateProvider() }
        return HotPepperShopCandidateProvider(apiKey: apiKey, session: session)
    }

    static func apiKey(from bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "HotPepperAPIKey") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    static func hotPepperRange(forSearchRadiusM radiusM: Double) -> Int {
        switch radiusM {
        case ...300: 1
        case ...500: 2
        case ...1_000: 3
        case ...2_000: 4
        default: 5
        }
    }

    private func fetchPage(near position: GeoPoint, range: Int, start: Int) async throws
        -> Page {
        let url = requestURL(near: position, range: range, start: start)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.httpStatus(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder.hotPepper.decode(APIResponse.self, from: data)
            if let errors = decoded.results.error, !errors.isEmpty {
                throw ProviderError.apiErrors(errors.map(\.message))
            }
            let shops = decoded.results.shop?.map(\.shop) ?? []
            return Page(available: decoded.results.resultsAvailable?.value ?? shops.count,
                        returned: decoded.results.resultsReturned?.value ?? shops.count,
                        shops: shops)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    private func requestURL(near position: GeoPoint, range: Int, start: Int) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "lat", value: String(position.latitude)),
            URLQueryItem(name: "lng", value: String(position.longitude)),
            URLQueryItem(name: "range", value: String(range)),
            URLQueryItem(name: "count", value: String(pageSize)),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "format", value: "json")
        ]
        return components.url!
    }

    private func sampledPoints(along route: [GeoPoint], searchRadiusM: Double) -> [GeoPoint] {
        let thresholdM = max(searchRadiusM - ShopPassageRules.defaultPassageRadiusM, 1)
        var sampled: [GeoPoint] = []
        for point in route {
            guard let last = sampled.last else {
                sampled.append(point)
                continue
            }
            if Geo.distanceM(last, point) >= thresholdM {
                sampled.append(point)
            }
        }
        return sampled
    }

    private struct Page {
        var available: Int
        var returned: Int
        var shops: [Shop]
    }

    private struct APIResponse: Decodable {
        var results: Results
    }

    private struct Results: Decodable {
        var resultsAvailable: FlexibleInt?
        var resultsReturned: FlexibleInt?
        var error: [APIError]?
        var shop: [ShopDTO]?
    }

    private struct APIError: Decodable {
        var message: String
    }

    private struct ShopDTO: Decodable {
        var id: String
        var name: String
        var lat: FlexibleDouble
        var lng: FlexibleDouble
        var genre: Genre?

        var shop: Shop {
            Shop(shopID: id, name: name, latitude: lat.value, longitude: lng.value,
                 category: genre?.name ?? "")
        }
    }

    private struct Genre: Decodable {
        var name: String
    }

    private struct FlexibleInt: Decodable {
        var value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
            } else if let string = try? container.decode(String.self),
                      let int = Int(string) {
                value = int
            } else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "Expected Int")
            }
        }
    }

    private struct FlexibleDouble: Decodable {
        var value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let double = try? container.decode(Double.self) {
                value = double
            } else if let string = try? container.decode(String.self),
                      let double = Double(string) {
                value = double
            } else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "Expected Double")
            }
        }
    }
}

private extension JSONDecoder {
    static var hotPepper: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
