import Foundation
import Loggers

/// Internal encoder that turns a redacted ``LogRecord`` into Elastic
/// Common Schema (ECS) JSON.
///
/// `ECSEncoder` is internal to the package. It is the encoder the
/// best-effort `ElasticLogger` path uses to build the JSON document
/// it hands to the bounded FIFO worker; the durable
/// `ElasticRemoteEngine` path does not invoke this encoder because
/// callers there hand pre-encoded `_bulk` document bytes to
/// `DurableRemoteQueue.enqueue(_:)` directly.
///
/// The encoder assumes its input has already been redacted by
/// ``DefaultRedactor``: private and sensitive segments must already
/// have been replaced with `<private>` / `<redacted>` strings before
/// the record reaches the encoder, and the encoder does not look at
/// privacy annotations again.
struct ECSEncoder: Sendable {
    /// The literal value emitted as the ECS `event.dataset` field on
    /// every record.
    static let dataset = "swift-loggers"

    /// Reserved top-level ECS field names produced by this encoder,
    /// plus the `labels` namespace itself. User attributes whose key
    /// matches one of these are relocated into a nested ``labels``
    /// object so a caller cannot overwrite the canonical record
    /// fields, and so `LogAttribute("labels", ...)` cannot clash with
    /// the namespace that holds collisions.
    private static let reservedKeys: Set<String> = [
        "@timestamp",
        "log.level",
        "message",
        "service.name",
        "event.dataset",
        "logger.domain",
        "labels"
    ]

    /// Encodes a redacted ``LogRecord`` as ECS-compatible JSON.
    ///
    /// The encoder is total: every supported ``Loggers/LogValue``
    /// case is mapped to a JSON-native value, non-finite ``Double``
    /// values are coerced to JSON `null`, and the resulting payload
    /// is always a valid JSON object, so this method does not
    /// throw and the caller cannot silently swallow a failure.
    ///
    /// - Parameters:
    ///   - record: The redacted record to encode. The encoder treats
    ///     the record as the source of truth for the reserved ECS
    ///     fields and ignores the attributes' privacy annotations
    ///     (redaction is the redactor's responsibility, not the
    ///     encoder's).
    ///   - serviceName: The value emitted as `service.name`.
    /// - Returns: UTF-8 JSON `Data`. Top-level keys are emitted in
    ///   sorted order so the output is byte-stable across runs.
    func encode(
        _ record: LogRecord,
        serviceName: String
    ) -> Data {
        let timestamp = Self.formatTimestamp(record.timestamp)
        let level = record.level.rawValue
        let message = record.message.redactedDescription
        let domain = record.domain.rawValue

        var body: [String: Any] = [
            "@timestamp": timestamp,
            "log.level": level,
            "message": message,
            "service.name": serviceName,
            "event.dataset": Self.dataset,
            "logger.domain": domain
        ]

        var labels: [String: Any] = [:]
        for attribute in record.attributes {
            let encodedValue = encodeValue(attribute.value)
            if Self.reservedKeys.contains(attribute.key) {
                labels[attribute.key] = encodedValue
            } else {
                body[attribute.key] = encodedValue
            }
        }
        if !labels.isEmpty {
            body["labels"] = labels
        }

        // The body is built only from values produced by `encodeValue`
        // (JSON-native types after NaN/Infinity coercion), the six
        // reserved fields above (all strings), and a single nested
        // string-keyed dictionary, so JSONSerialization should always
        // succeed. The do/catch is defensive: if a future Foundation
        // change rejects something we accepted, fall back to a
        // hand-rolled minimal ECS document containing the six
        // reserved fields. This drops user attributes for that one
        // entry but keeps the canonical record interpretable on the
        // other end -- preferable to either an empty `{}` payload or
        // a `try!` crash on the logging path.
        do {
            return try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys]
            )
        } catch {
            return Self.minimalReservedFallback(
                timestamp: timestamp,
                level: level,
                message: message,
                serviceName: serviceName,
                domain: domain
            )
        }
    }

    /// Hand-builds a minimal ECS document carrying only the six
    /// reserved fields, in sorted-key order, with each string value
    /// JSON-escaped manually so the result does not depend on
    /// `JSONSerialization` (the very thing whose failure put us in
    /// this branch).
    static func minimalReservedFallback(
        timestamp: String,
        level: String,
        message: String,
        serviceName: String,
        domain: String
    ) -> Data {
        // Sorted lexicographically so the fallback shape matches
        // the sorted-keys output of the normal path minus user
        // attributes.
        let parts = [
            "\"@timestamp\":\(jsonEscape(timestamp))",
            "\"event.dataset\":\(jsonEscape(Self.dataset))",
            "\"log.level\":\(jsonEscape(level))",
            "\"logger.domain\":\(jsonEscape(domain))",
            "\"message\":\(jsonEscape(message))",
            "\"service.name\":\(jsonEscape(serviceName))"
        ]
        return Data("{\(parts.joined(separator: ","))}".utf8)
    }

    /// Returns `value` wrapped in double quotes with the JSON-string
    /// escape rules applied. Used only by the fallback path; the
    /// normal path goes through `JSONSerialization`.
    private static func jsonEscape(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let scalar where scalar.value < 0x20:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }

    private func encodeValue(_ value: LogValue) -> Any {
        switch value {
        case let .string(string):
            return string
        case let .integer(integer):
            return NSNumber(value: integer)
        case let .double(double):
            // JSONSerialization rejects NaN and infinity. Coerce to
            // JSON null so the encoder stays total.
            return double.isFinite ? NSNumber(value: double) : NSNull()
        case let .bool(bool):
            return NSNumber(value: bool)
        case let .date(date):
            return Self.formatTimestamp(date)
        case let .array(values):
            return values.map { encodeValue($0) }
        case let .object(dictionary):
            var result: [String: Any] = [:]
            for (key, nested) in dictionary {
                result[key] = encodeValue(nested)
            }
            return result
        case .null:
            return NSNull()
        @unknown default:
            // Future LogValue cases that this encoder is not aware of
            // are emitted as JSON null rather than crashed on. This is
            // only reachable if the core swift-logger module ships a
            // new case ahead of an Elastic adapter update.
            return NSNull()
        }
    }

    /// Formats `date` as ISO 8601 with millisecond precision in UTC,
    /// for example `"2026-04-30T12:00:00.000Z"`. The format is fixed
    /// (locale `en_US_POSIX`, time zone UTC) so golden JSON tests are
    /// stable across host locales. Access goes through a lock so the
    /// shared `DateFormatter` instance is safe to call from concurrent
    /// `ElasticLogger.log` invocations.
    static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static let timestampFormatter = LockedTimestampFormatter()
}

/// A small `DateFormatter` wrapper that serializes access through an
/// `NSLock` so the encoder can keep one shared formatter without
/// running into `DateFormatter`'s "not safe for concurrent use"
/// caveat.
private final class LockedTimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: DateFormatter

    init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Use a fixed-offset zero-second-from-GMT zone so the
        // formatter does not depend on `TimeZone(identifier:)`
        // looking up the IANA database, which would silently fall
        // back to the host time zone if the lookup ever returned
        // nil. The zero offset is always valid.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        self.formatter = formatter
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}
