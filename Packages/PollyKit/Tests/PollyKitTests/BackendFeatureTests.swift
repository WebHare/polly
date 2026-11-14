import Foundation
import Testing
@testable import PollyKit

private func problem(_ severity: Severity = .critical, service: String = "HTTP", acknowledged: Bool = false,
                     downtimeDepth: Int = 0) -> ServiceProblem {
    ServiceProblem(host: "web1", service: service, severity: severity, acknowledged: acknowledged, downtimeDepth: downtimeDepth)
}

struct NotificationPolicyTests {
    @Test func firstResultIsTheBaseline() {
        #expect(NotificationPolicy.changes(previous: nil, current: [problem()]).isEmpty)
    }

    @Test func reportsNewChangedAndRecoveredProblems() {
        let changes = NotificationPolicy.changes(previous: [problem(.warning), problem(service: "Disk")],
                                                 current: [problem(.critical), problem(service: "Load")])
        #expect(changes.raised.map(\.id) == ["web1/HTTP", "web1/Load"])
        #expect(changes.recovered.map(\.id) == ["web1/Disk"])
        #expect(NotificationPolicy.changes(previous: [problem()], current: [problem()]).isEmpty)
    }

    @Test func staysQuietForAcknowledgedProblemsAndDowntime() {
        #expect(NotificationPolicy.changes(previous: [], current: [problem(acknowledged: true)]).isEmpty)
        #expect(NotificationPolicy.changes(previous: [], current: [problem(downtimeDepth: 1)]).isEmpty)
        // A check that recovers during its downtime was planned work.
        #expect(NotificationPolicy.changes(previous: [problem(downtimeDepth: 1)], current: []).isEmpty)
        #expect(NotificationPolicy.changes(previous: [problem(acknowledged: true)], current: []).recovered.count == 1)
    }
}

struct NagiosLinkTests {
    private let client = NagiosClient(endpoint: URL(string: "http://mon.example.com/ops/nagios/cgi-bin/statusjson.cgi")!,
                                      username: "alice", password: "s3cret")
    private let page = URL(string: "https://mon.example.com/nagios/cgi-bin/extinfo.cgi")!

    @Test func checkURLEncodesHostAndService() throws {
        let url = try client.checkURL(for: ServiceProblem(host: "host & one", service: "DB + web?", severity: .critical))
        #expect(url.absoluteString
            == "http://mon.example.com/ops/nagios/cgi-bin/extinfo.cgi?host=host%20%26%20one&service=DB%20%2B%20web%3F&type=2")
    }

    @Test func relatedURLPrefersActionOverNotes() throws {
        let html = "<A HREF='/notes'><img alt='View Additional Notes For This Service'></A>"
            + "<A HREF='https://cms.example/?a=1&amp;b=2'><img alt='Perform Additional Actions On This Service'></A>"
        #expect(try NagiosHTML.relatedURL(html: html, pageURL: page).absoluteString == "https://cms.example/?a=1&b=2")
        let notes = "<a href='/notes'><img alt='View Additional Notes For This Service'></a>"
        #expect(try NagiosHTML.relatedURL(html: notes, pageURL: page).absoluteString == "https://mon.example.com/notes")
        #expect(throws: BackendError.self) { try NagiosHTML.relatedURL(html: "<a href='/x'>other</a>", pageURL: page) }
    }

    @Test func relatedURLRejectsUnsafeTargets() {
        for unsafe in ["javascript:alert(1)", "file:///tmp/foo", "https://user:password@cms.example", "https://cms.example/$HOSTNAME$"] {
            #expect(throws: BackendError.self) {
                try NagiosHTML.relatedURL(html: "<a href='\(unsafe)'><img alt='Perform Additional Actions On This Service'></a>", pageURL: page)
            }
        }
    }
}

struct NagiosCommandFormTests {
    private let target = ServiceProblem(host: "host & one", service: "Disk", severity: .critical)

    @Test func readsFormInputsIncludingTheUnclosedCSRFField() {
        // Nagios emits the nagFormId input without its closing '>' in some versions.
        let form = NagiosCommandForm.inputs("<INPUT TYPE='hidden' NAME='nagFormId' VALUE='abc123'\n<INPUT NAME='cmd_typ' VALUE='34'>"
            + "<input name=host value='host &amp; one'><input name='service' value='Disk'><input name='cmd_mod' value='2'>")
        #expect(form == ["nagFormId": "abc123", "cmd_typ": "34", "host": "host & one", "service": "Disk", "cmd_mod": "2"])
    }

    @Test func acknowledgeBodyKeepsTheCSRFTokenAndEncodesStrictly() throws {
        let input = CommandInput(author: "Wouter", comment: "Check + fix & wait")
        let body = String(decoding: try NagiosCommandForm.body(kind: .acknowledge, problem: target, input: input,
                                                               form: ["nagFormId": "abc123"]), as: UTF8.self)
        #expect(body == "cmd_mod=2&cmd_typ=34&com_author=Wouter&com_data=Check%20%2B%20fix%20%26%20wait"
            + "&host=host%20%26%20one&nagFormId=abc123&service=Disk&sticky_ack=on")
        let notifying = try NagiosCommandForm.body(kind: .acknowledge, problem: target,
                                                   input: CommandInput(author: "me", comment: "x", notify: true), form: [:])
        #expect(String(decoding: notifying, as: UTF8.self).contains("send_notification=on"))
    }

    /// These values end up in Nagios' semicolon-delimited external command file.
    @Test func rejectsEmptyAndInjectingValues() {
        for bad in ["", "   ", "inject;command", "line\nbreak"] {
            #expect(throws: BackendError.self) {
                try NagiosCommandForm.body(kind: .acknowledge, problem: target, input: CommandInput(author: "me", comment: bad), form: [:])
            }
        }
    }

    @Test func downtimeBodyAndDateValidation() throws {
        let form = ["nagFormId": "token", "start_time": "11-13-2026 09:00:00"]
        let input = CommandInput(author: "me", comment: "Maintenance", start: "11-13-2026 15:00:00", end: "11-13-2026 16:00:00")
        let body = String(decoding: try NagiosCommandForm.body(kind: .downtime, problem: target, input: input, form: form), as: UTF8.self)
        #expect(body.contains("cmd_typ=56"))
        #expect(body.contains("fixed=1"))
        #expect(body.contains("end_time=11-13-2026%2016%3A00%3A00"))

        // date_format=iso8601, as on monitor.webhare.net. Without a token in the form, none is sent.
        let iso = CommandInput(author: "me", comment: "Maintenance", start: "2026-11-14 23:11:46", end: "2026-11-15 01:11:46")
        let isoBody = String(decoding: try NagiosCommandForm.body(kind: .downtime, problem: target, input: iso,
                                                                  form: ["start_time": "2026-11-14 23:11:46"]), as: UTF8.self)
        #expect(isoBody.contains("start_time=2026-11-14%2023%3A11%3A46"))
        #expect(!isoBody.contains("nagFormId"))

        for (start, end) in [("11-13-2026 16:00:00", "11-13-2026 15:00:00"), ("02-30-2026 10:00:00", "03-01-2026 10:00:00"),
                             ("11-13-2026 10:00:00", "11-13-2026 25:00:00"), ("11-13-2026", "11-14-2026"), ("", "")] {
            #expect(throws: BackendError.self) {
                try NagiosCommandForm.body(kind: .downtime, problem: target,
                                           input: CommandInput(author: "me", comment: "x", start: start, end: end), form: form)
            }
        }
    }

    @Test func http200AloneIsNotConfirmation() throws {
        try NagiosCommandForm.validateResult("<DIV CLASS='infoMessage'>Your command request was successfully submitted to Nagios for processing.<BR></DIV>")
        for html in ["<html>Login</html>", "<div class='errorMessage'>Not authorized</div>",
                     "<p>Error: Invalid or missing CSRF cookie!</p>", "<div>successfully submitted</div>"] {
            #expect(throws: BackendError.self) { try NagiosCommandForm.validateResult(html) }
        }
    }
}
