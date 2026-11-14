import Foundation
import Testing
@testable import NaggieKit

struct NagiosClientTests {
    private let client = NagiosClient(endpoint: URL(string: "https://mon.example.com/nagios/cgi-bin/statusjson.cgi")!,
                                      username: "alice", password: "s3cret")

    @Test func buildsRequestWithQueryAndBasicAuth() throws {
        let request = client.request(query: "servicelist", extra: [URLQueryItem(name: "servicestatus", value: "warning critical")])
        let url = try #require(request.url?.absoluteString)
        #expect(url == "https://mon.example.com/nagios/cgi-bin/statusjson.cgi?query=servicelist&servicestatus=warning%20critical")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6czNjcmV0")
    }

    @Test func decodesHostCount() throws {
        let json = """
            {"format_version":0,
             "result":{"query_time":1,"cgi":"statusjson.cgi","user":"alice","query":"hostcount","type_code":0,"type_text":"Success","message":""},
             "data":{"count":{"up":10,"down":1,"unreachable":0,"pending":2}}}
            """
        let envelope: StatusJSONEnvelope<CountPayload<HostCounts>> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        #expect(envelope.data?.count == HostCounts(up: 10, down: 1, unreachable: 0, pending: 2))
    }

    @Test func decodesProblemsSortedBySeverity() throws {
        let json = """
            {"result":{"type_code":0},
             "data":{"servicelist":{"web1":{"HTTP":4,"Disk":16},"db1":{"Load":8,"Ping":2}}}}
            """
        let envelope: StatusJSONEnvelope<ServiceListPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        let problems = try #require(envelope.data?.problems)
        #expect(problems.map(\.id) == ["web1/Disk", "web1/HTTP", "db1/Load"])
    }

    @Test func decodesDetailedServiceList() throws {
        let json = """
            {"result":{"type_code":0},
             "data":{"servicelist":{"web1":{"HTTP":{"host_name":"web1","description":"HTTP","status":16,
                                                    "last_state_change":1731590000000,"plugin_output":"down"},
                                            "Disk":{"status":4,"last_state_change":0}}}}}
            """
        let envelope: StatusJSONEnvelope<ServiceListPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        let problems = try #require(envelope.data?.problems)
        #expect(problems.map(\.id) == ["web1/HTTP", "web1/Disk"])
        #expect(problems[0].since == Date(timeIntervalSince1970: 1_731_590_000))
        #expect(problems[1].since == nil)
    }

    @Test func mapsErrors() {
        #expect(throws: NagiosClientError.unauthorized) {
            let _: StatusJSONEnvelope<IgnoredPayload> = try NagiosClient.decode(data: Data(), statusCode: 401)
        }
        #expect(throws: NagiosClientError.notStatusJSON) {
            let _: StatusJSONEnvelope<IgnoredPayload> = try NagiosClient.decode(data: Data("<html>".utf8), statusCode: 200)
        }
        #expect(throws: NagiosClientError.queryFailed("Unknown query")) {
            let json = #"{"result":{"type_code":1,"type_text":"Error","message":"Unknown query"}}"#
            let _: StatusJSONEnvelope<IgnoredPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        }
    }
}

struct DurationFormattingTests {
    @Test func short() {
        #expect(DurationFormatting.short(30) == "<1m")
        #expect(DurationFormatting.short(3 * 60 + 59) == "3m")
        #expect(DurationFormatting.short(2 * 3600 + 1800) == "2h")
        #expect(DurationFormatting.short(3 * 86400 + 7200) == "3d")
        #expect(DurationFormatting.short(-5) == "<1m")
    }
}
