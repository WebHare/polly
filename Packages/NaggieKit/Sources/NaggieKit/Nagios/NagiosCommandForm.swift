import Foundation

extension CommandKind {
    /// Nagios' `cmd_typ`: 34 = acknowledge a service problem, 56 = schedule downtime for a service.
    var nagiosCommandType: String {
        switch self {
        case .acknowledge: "34"
        case .downtime: "56"
        }
    }
}

/// Reads and fills in the `cmd.cgi` command form, and checks Nagios' answer to it.
enum NagiosCommandForm {
    /// Name/value pairs of all `<input>` elements.
    static func inputs(_ html: String) -> [String: String] {
        var fields: [String: String] = [:]
        // `[^<]*` instead of `[^>]*`: some Nagios versions write the nagFormId input without its closing `>`.
        for match in NagiosHTML.matches(#"<input\b([^<]*)"#, in: html) {
            let attributes = NagiosHTML.attributes(match[1])
            if let name = attributes["name"] { fields[name] = attributes["value"] ?? "" }
        }
        return fields
    }

    /// The POST body for a command. `form` is the fetched form, which supplies the CSRF token and the
    /// date notation the server uses.
    static func body(kind: CommandKind, problem: ServiceProblem, input: CommandInput, form: [String: String]) throws -> Data {
        // Nagios forwards these fields to its semicolon-delimited external command file.
        for value in [problem.host, problem.service, input.author, input.comment] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains(";") else {
                throw BackendError("Host, check, author and comment are required and cannot contain semicolons or control characters.")
            }
        }
        var fields = ["cmd_typ": kind.nagiosCommandType, "cmd_mod": "2", "host": problem.host, "service": problem.service,
                      "com_author": input.author, "com_data": input.comment]
        if let token = form["nagFormId"] { fields["nagFormId"] = token }
        switch kind {
        case .acknowledge:
            fields["sticky_ack"] = "on"
            if input.notify { fields["send_notification"] = "on" }
        case .downtime:
            for value in [input.start, input.end] {
                guard !value.isEmpty, value.range(of: #"^[0-9/:T .-]+$"#, options: .regularExpression) != nil else {
                    throw BackendError("Enter start and end times in the Nagios server's date format and time zone.")
                }
            }
            guard validPeriod(start: input.start, end: input.end, sample: form["start_time"] ?? input.start) else {
                throw BackendError("Enter valid server-local dates and times, with the end after the start, in the format supplied by Nagios.")
            }
            fields.merge(["start_time": input.start, "end_time": input.end, "fixed": "1", "trigger": "0", "hours": "2", "minutes": "0"]) { _, new in new }
        }
        return Data(encode(fields).utf8)
    }

    private static func validPeriod(start: String, end: String, sample: String) -> Bool {
        let iso = sample.range(of: #"^[0-9]{4}-"#, options: .regularExpression) != nil
        let formats = iso ? ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] : ["MM-dd-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm:ss"]
        // Compare server wall times without applying this device's time zone. The server resolves DST.
        return formats.contains { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            func parse(_ value: String) -> Date? {
                guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
                return date
            }
            guard parse(sample) != nil, let first = parse(start), let last = parse(end) else { return false }
            return last > first
        }
    }

    /// Nagios answers HTTP 200 to almost everything, including login pages and permission errors, so only
    /// its explicit success message counts as confirmation.
    static func validateResult(_ html: String) throws {
        // The text right after each opening tag, not `<div>(.*?)</div>`: a non-greedy match stops at the inner
        // `</div>` when Nagios nests the message in `<DIV ALIGN=CENTER>`, so the message div itself never matched.
        let messages = NagiosHTML.matches(#"<div\b([^>]*)>([^<]*)"#, in: html)
        guard messages.contains(where: {
            NagiosHTML.attributes($0[1])["class"]?.lowercased() == "infomessage" &&
            $0[2].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Your command request was successfully submitted to Nagios for processing.")
        }) else {
            throw BackendError("Nagios did not confirm submission. Check your command permissions and the check in your browser before retrying.")
        }
    }

    /// Form/query encoding with only `A-Za-z0-9-._~` unescaped and keys sorted. Stricter than
    /// `URLComponents`, because Nagios decodes `+` as a space.
    static func encode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }
}
