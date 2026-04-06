import Foundation
@testable import ClaudeBattery

/// A test double for URLSession that returns preconfigured responses.
/// Thread-safe via actor-isolated request history.
final class MockHTTPSession: HTTPDataFetching, @unchecked Sendable {

    // MARK: - Stubbing

    var responseData: Data = Data()
    var responseStatusCode: Int = 200
    var responseError: Error?

    // MARK: - Request capture (actor-isolated for async safety)

    private let _storage = RequestStorage()

    var capturedRequests: [URLRequest] { _storage.requests }
    var lastRequest: URLRequest? { _storage.requests.last }

    // MARK: - HTTPDataFetching

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        _storage.append(request)

        if let error = responseError {
            throw error
        }

        let url = request.url ?? URL(string: "https://claude.ai")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: responseStatusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (responseData, response)
    }
}

/// Simple synchronized storage for captured requests.
private final class RequestStorage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MockHTTPSession.requests")
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] {
        queue.sync { _requests }
    }

    func append(_ request: URLRequest) {
        queue.sync { _requests.append(request) }
    }
}
