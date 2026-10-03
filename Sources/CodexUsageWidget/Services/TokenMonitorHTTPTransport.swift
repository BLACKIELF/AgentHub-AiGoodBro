import Foundation

struct TokenMonitorHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

protocol TokenMonitorHTTPTransport: AnyObject {
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> TokenMonitorHTTPResponse
}

enum TokenMonitorHTTPTransportError: Error {
    case responseTooLarge
    case invalidResponse
    case transport
}

final class TokenMonitorURLSessionTransport: TokenMonitorHTTPTransport {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> TokenMonitorHTTPResponse {
        guard (1...16_777_216).contains(maximumResponseBytes) else {
            throw TokenMonitorHTTPTransportError.invalidResponse
        }
        let delegate = TokenMonitorBoundedResponseDelegate(maximumResponseBytes: maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setCompletion { continuation.resume(with: $0) }
                let sessionConfiguration = configuration.copy() as! URLSessionConfiguration
                sessionConfiguration.urlCache = nil
                sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
                sessionConfiguration.httpCookieStorage = nil
                sessionConfiguration.httpShouldSetCookies = false
                sessionConfiguration.timeoutIntervalForRequest = request.timeoutInterval
                sessionConfiguration.timeoutIntervalForResource = request.timeoutInterval
                let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: request)
                delegate.attach(session: session, task: task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class TokenMonitorBoundedResponseDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var response: HTTPURLResponse?
    private var body = Data()
    private var completion: ((Result<TokenMonitorHTTPResponse, Error>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancellationRequested = false

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func setCompletion(_ completion: @escaping (Result<TokenMonitorHTTPResponse, Error>) -> Void) {
        lock.lock()
        let cancelled = cancellationRequested
        if !cancelled { self.completion = completion }
        lock.unlock()
        if cancelled { completion(.failure(CancellationError())) }
    }

    func attach(session: URLSession, task: URLSessionDataTask) {
        lock.lock()
        self.session = session
        self.task = task
        let cancel = cancellationRequested
        lock.unlock()
        if cancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(TokenMonitorHTTPTransportError.invalidResponse))
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            completionHandler(.cancel)
            finish(.failure(TokenMonitorHTTPTransportError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard completion != nil else {
            lock.unlock()
            return
        }
        guard data.count <= maximumResponseBytes - body.count else {
            let task = self.task
            lock.unlock()
            task?.cancel()
            finish(.failure(TokenMonitorHTTPTransportError.responseTooLarge))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)  // Do not forward a bearer credential across redirects.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
                return
            }
            finish(.failure(TokenMonitorHTTPTransportError.transport))
            return
        }
        lock.lock()
        let response = self.response
        let body = self.body
        lock.unlock()
        guard let response else {
            finish(.failure(TokenMonitorHTTPTransportError.invalidResponse))
            return
        }
        finish(.success(TokenMonitorHTTPResponse(statusCode: response.statusCode, body: body)))
    }

    private func finish(_ result: Result<TokenMonitorHTTPResponse, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        let session = self.session
        self.session = nil
        task = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        callback?(result)
        session?.finishTasksAndInvalidate()
    }
}
