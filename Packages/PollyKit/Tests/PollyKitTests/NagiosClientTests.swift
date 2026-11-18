import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PollyKit

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

    @Test func decodesProblemDetails() throws {
        let json = """
            {"result":{"type_code":0},
             "data":{"servicelist":{"web1":{"HTTP":{"status":16,"last_check":1731590060000,
                 "plugin_output":" HTTP CRITICAL - timeout \\n","long_plugin_output":"line 1\\\\nline 2",
                 "problem_has_been_acknowledged":true,"scheduled_downtime_depth":2}}}}}
            """
        let envelope: StatusJSONEnvelope<ServiceListPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        let problem = try #require(envelope.data?.problems.first)
        #expect(problem.output == "HTTP CRITICAL - timeout")
        #expect(problem.longOutput == "line 1\nline 2")
        #expect(problem.lastCheck == Date(timeIntervalSince1970: 1_731_590_060))
        #expect(problem.acknowledged)
        #expect(problem.downtimeDepth == 2)
    }

    @Test func decodesStateTypeAttemptsAndNextCheck() throws {
        let json = """
            {"result":{"type_code":0},
             "data":{"servicelist":{"web1":{"HTTP":{"status":16,"state_type":1,"current_attempt":3,"max_attempts":3,
                                                    "next_check":1731590120000},
                                            "Disk":{"status":4,"state_type":"soft","current_attempt":1,"max_attempts":4},
                                            "Load":{"status":8}}}}}
            """
        let envelope: StatusJSONEnvelope<ServiceListPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        let problems = try #require(envelope.data?.problems)
        let http = try #require(problems.first { $0.service == "HTTP" })
        #expect(http.checkAttempt == CheckAttempt(hard: true, current: 3, max: 3))
        #expect(http.checkAttempt?.label == "HARD 3/3")
        #expect(http.nextCheck == Date(timeIntervalSince1970: 1_731_590_120))
        let disk = try #require(problems.first { $0.service == "Disk" })
        #expect(disk.checkAttempt?.label == "SOFT 1/4")
        let load = try #require(problems.first { $0.service == "Load" })
        #expect(load.checkAttempt == nil)
        #expect(load.nextCheck == nil)
    }

    @Test func decodesDownAndUnreachableHosts() throws {
        let json = """
            {"result":{"type_code":0},
             "data":{"hostlist":{"web1":{"name":"web1","status":4,"last_state_change":1731590000000,
                                         "plugin_output":"PING CRITICAL - Packet loss = 100%","problem_has_been_acknowledged":true,
                                         "scheduled_downtime_depth":1,"state_type":1,"current_attempt":10,"max_attempts":10},
                                 "db1":{"status":8},"mail":{"status":2}}}}
            """
        let envelope: StatusJSONEnvelope<HostListPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        let problems = try #require(envelope.data?.problems)
        #expect(problems.map(\.host) == ["db1", "web1"])
        #expect(problems.map(\.hostState) == [.unreachable, .down])
        #expect(problems.allSatisfy { $0.severity == .critical && $0.service.isEmpty && $0.isHost })
        let web1 = problems[1]
        #expect(web1.title == "Host down")
        #expect(web1.output == "PING CRITICAL - Packet loss = 100%")
        #expect(web1.since == Date(timeIntervalSince1970: 1_731_590_000))
        #expect(web1.acknowledged)
        #expect(web1.downtimeDepth == 1)
        #expect(web1.checkAttempt?.label == "HARD 10/10")
        #expect(problems[0].title == "Host unreachable")
        #expect(problems.map(\.stateLabel) == ["UNREACHABLE", "DOWN"])
        #expect(ServiceProblem(host: "a", service: "x", severity: .warning).stateLabel == nil)
    }

    /// `enable_notifications` is the program-wide switch for host and service notifications (cgi/statusjson.c).
    @Test func decodesTheProgramWideNotificationSwitch() throws {
        let json = """
            {"result":{"type_code":0},
             "data":{"programstatus":{"version":"4.5.14","nagios_pid":1234,"program_start":1731500000000,
                                      "enable_notifications":false,"execute_service_checks":true}}}
            """
        let envelope: StatusJSONEnvelope<ProgramStatusPayload> = try NagiosClient.decode(data: Data(json.utf8), statusCode: 200)
        #expect(envelope.data?.programstatus?.notificationsEnabled == false)
        let older: StatusJSONEnvelope<ProgramStatusPayload> = try NagiosClient.decode(
            data: Data(#"{"result":{"type_code":0},"data":{"programstatus":{"version":"4.4.0"}}}"#.utf8), statusCode: 200)
        #expect(older.data?.programstatus?.notificationsEnabled == nil)
    }

    /// A successful result without a payload must never be read as "no problems".
    @Test func missingDataIsNotHealthy() {
        #expect(throws: NagiosClientError.notStatusJSON) {
            let _: StatusJSONEnvelope<ServiceListPayload> = try NagiosClient.decode(data: Data(#"{"result":{"type_code":0}}"#.utf8), statusCode: 200)
        }
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
