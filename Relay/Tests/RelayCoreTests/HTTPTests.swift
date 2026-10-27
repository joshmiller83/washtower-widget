import Foundation
import Testing
@testable import RelayCore

@Suite struct HTTPParserTests {
    func parse(_ text: String) -> HTTPRequestParser.Result {
        HTTPRequestParser.parse(Data(text.utf8))
    }

    @Test func getWithHeaders() throws {
        let result = parse("GET /v1/state?x=1 HTTP/1.1\r\nHost: localhost\r\nAuthorization:  Bearer abc123 \r\nX-Dup: a\r\nx-dup: b\r\n\r\n")
        guard case .complete(let request) = result else { Issue.record("got \(result)"); return }
        #expect(request.method == "GET")
        #expect(request.target == "/v1/state?x=1")
        #expect(request.pathComponents == ["v1", "state"])
        #expect(request.header("HOST") == "localhost")
        #expect(request.header("x-dup") == "a, b")
        #expect(request.bearerToken == "abc123")
        #expect(request.body.isEmpty)
    }

    @Test func bodyByContentLength() throws {
        let body = #"{"name":"iPhone"}"#
        let head = "PUT /v1/devices/abc HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        // Headers and part of the body: wait for more.
        #expect(parse(head + body.prefix(5)) == .incomplete)
        guard case .complete(let request) = parse(head + body) else { Issue.record("incomplete"); return }
        #expect(request.body == Data(body.utf8))
        // Bytes past Content-Length aren't part of the body.
        guard case .complete(let extra) = parse(head + body + "GARBAGE") else { Issue.record("incomplete"); return }
        #expect(extra.body == Data(body.utf8))
    }

    @Test func headersArriveInPieces() {
        #expect(parse("GET /v1/hea") == .incomplete)
        #expect(parse("GET /v1/health HTTP/1.1\r\nHost: x\r\n") == .incomplete)
    }

    @Test func chunkedBody() throws {
        let head = "PUT /v1/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        #expect(parse(head + "5\r\nhel") == .incomplete)
        guard case .complete(let request) = parse(head + "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n") else {
            Issue.record("incomplete"); return
        }
        #expect(String(decoding: request.body, as: UTF8.self) == "hello world")
    }

    @Test func rejectsBadRequests() {
        #expect(parse("GARBAGE\r\n\r\n") == .invalid(status: 400, reason: "malformed request line"))
        #expect(parse("GET /x HTTP/2\r\n\r\n") == .invalid(status: 505, reason: "only HTTP/1.x is supported"))
        #expect(parse("GET /x HTTP/1.1\r\nno colon\r\n\r\n") == .invalid(status: 400, reason: "malformed header line"))
        #expect(parse("PUT /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n") == .invalid(status: 400, reason: "bad content-length"))
        #expect(parse("PUT /x HTTP/1.1\r\nContent-Length: 999999\r\n\r\n") == .invalid(status: 413, reason: "body too large"))
        #expect(parse("GET /" + String(repeating: "a", count: 20_000)) == .invalid(status: 431, reason: "headers too large"))
    }

    @Test func percentDecodedPath() {
        guard case .complete(let request) = parse("DELETE /v1/devices/a%20b/activities/C-1 HTTP/1.1\r\n\r\n") else {
            Issue.record("incomplete"); return
        }
        #expect(request.pathComponents == ["v1", "devices", "a b", "activities", "C-1"])
    }

    @Test func bearerParsing() {
        func request(_ authorization: String?) -> HTTPRequest {
            HTTPRequest(method: "GET", target: "/", headers: authorization.map { ["authorization": $0] } ?? [:], body: Data())
        }
        #expect(request("bearer xyz").bearerToken == "xyz")
        #expect(request("Basic xyz").bearerToken == nil)
        #expect(request("Bearer").bearerToken == nil)
        #expect(request(nil).bearerToken == nil)
    }

    @Test func responseSerialization() {
        let text = String(decoding: HTTPResponse.ok.serialized(), as: UTF8.self)
        #expect(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{\"ok\":true}")
    }
}

@Suite struct RelayAPITests {
    let key = String(repeating: "f0", count: 32)
    let relay: Relay
    let api: RelayAPI

    init() {
        let stateFile = StateFile(url: Fixture.temporaryDirectory().appending(path: "state.json"))
        relay = Relay(state: RelayState(), stateFile: stateFile, source: FakeLaundrySource(), sender: FakePushSender(),
                      composer: Fixture.composer())
        api = RelayAPI(relay: relay, key: key)
    }

    func call(_ method: String, _ path: String, body: String? = nil, auth: String?? = .none) async -> (Int, [String: Any]) {
        var headers: [String: String] = [:]
        switch auth {
        case .none: headers["authorization"] = "Bearer \(key)"
        case .some(let value?): headers["authorization"] = value
        case .some(nil): break
        }
        let request = HTTPRequest(method: method, target: path, headers: headers, body: Data((body ?? "").utf8))
        let response = await api.handle(request)
        let json = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
        return (response.status, json)
    }

    @Test func healthNeedsNoKey() async {
        let (status, json) = await call("GET", "/v1/health", auth: .some(nil))
        #expect(status == 200)
        #expect(json["ok"] as? Bool == true)
    }

    @Test func everythingElseNeedsTheKey() async {
        #expect(await call("GET", "/v1/state", auth: .some(nil)).0 == 401)
        #expect(await call("GET", "/v1/state", auth: "Bearer wrong").0 == 401)
        #expect(await call("GET", "/v1/state", auth: "Bearer \(key)x").0 == 401)
        #expect(await call("PUT", "/v1/devices/phone", body: #"{"name":"x"}"#, auth: .some(nil)).0 == 401)
        #expect(await call("GET", "/v1/nope", auth: .some(nil)).0 == 401)
        #expect(await call("GET", "/v1/nope").0 == 404)
    }

    @Test func stateBeforeAnyPoll() async throws {
        let request = HTTPRequest(method: "GET", target: "/v1/state", headers: ["authorization": "Bearer \(key)"], body: Data())
        let body = String(decoding: await api.handle(request).body, as: UTF8.self)
        #expect(body == #"{"error":null,"sessionActive":false,"state":null}"#)
    }

    @Test func stateAfterAPoll() async throws {
        await relay.process(Fixture.state(washer: "RUNNING", washerLeft: 30, at: Fixture.t0), now: Fixture.t0)
        let (status, json) = await call("GET", "/v1/state")
        #expect(status == 200)
        #expect(json["sessionActive"] as? Bool == true)
        let state = try #require(json["state"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: state)
        #expect(try JSONDecoder().decode(LaundryActivityState.self, from: data).drums.first?.label == "Washing")
    }

    @Test func registerDeviceAndActivity() async throws {
        let token = String(repeating: "AB", count: 32)
        #expect(await call("PUT", "/v1/devices/phone-1", body: #"{"name":"iPhone","pushToStartToken":"\#(token)"}"#).0 == 200)
        var state = await relay.state
        #expect(state.devices["phone-1"]?.pushToStartToken == token.lowercased())

        // No token in the body leaves the stored one alone.
        #expect(await call("PUT", "/v1/devices/phone-1", body: #"{"name":"Renamed","pushToStartToken":null}"#).0 == 200)
        state = await relay.state
        #expect(state.devices["phone-1"]?.name == "Renamed")
        #expect(state.devices["phone-1"]?.pushToStartToken == token.lowercased())

        #expect(await call("PUT", "/v1/devices/phone-1/activities/ACT-1", body: #"{"pushToken":"\#(token)"}"#).0 == 200)
        #expect(await relay.state.session.activities.map(\.activityId) == ["ACT-1"])
        #expect(await call("DELETE", "/v1/devices/phone-1/activities/ACT-1").0 == 200)
        #expect(await relay.state.session.activities.isEmpty)
        // Deleting again is fine.
        #expect(await call("DELETE", "/v1/devices/phone-1/activities/ACT-1").0 == 200)
    }

    @Test func rejectsBadBodies() async {
        #expect(await call("PUT", "/v1/devices/phone", body: "not json").0 == 400)
        #expect(await call("PUT", "/v1/devices/phone", body: #"{"pushToStartToken":"abcd"}"#).0 == 400)
        #expect(await call("PUT", "/v1/devices/phone", body: #"{"name":"x","pushToStartToken":"not hex!"}"#).0 == 400)
        #expect(await call("PUT", "/v1/devices/phone/activities/a", body: #"{"pushToken":"zz"}"#).0 == 400)
        #expect(await call("POST", "/v1/devices/phone", body: #"{"name":"x"}"#).0 == 405)
        #expect(await call("DELETE", "/v1/state").0 == 405)
    }
}

/// The real listener on a free localhost port, through URLSession.
@Suite struct HTTPServerTests {
    @Test func servesOverTCP() async throws {
        let key = String(repeating: "0a", count: 32)
        let relay = Relay(state: RelayState(), stateFile: StateFile(url: Fixture.temporaryDirectory().appending(path: "state.json")),
                          source: FakeLaundrySource(), sender: nil, composer: Fixture.composer())
        let api = RelayAPI(relay: relay, key: key)
        let server = try HTTPServer(host: "127.0.0.1", port: 0) { await api.handle($0) }
        let port = try await server.start()
        defer { server.stop() }
        #expect(port != 0)

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .ephemeral)

        let (health, healthResponse) = try await session.data(from: base.appending(path: "v1/health"))
        #expect((healthResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: health, as: UTF8.self) == #"{"ok":true}"#)

        var put = URLRequest(url: base.appending(path: "v1/devices/phone"))
        put.httpMethod = "PUT"
        put.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        put.httpBody = Data(#"{"name":"iPhone","pushToStartToken":"\#(String(repeating: "cd", count: 32))"}"#.utf8)
        let (_, putResponse) = try await session.data(for: put)
        #expect((putResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(await relay.state.devices["phone"]?.name == "iPhone")

        let (_, unauthorized) = try await session.data(from: base.appending(path: "v1/state"))
        #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
    }
}
