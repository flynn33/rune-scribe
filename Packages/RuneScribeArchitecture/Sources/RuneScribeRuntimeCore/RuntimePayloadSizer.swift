import Foundation
import RuneScribeContracts

enum RuntimePayloadSizer {
    static func byteCount<Value>(_ value: Value, maximum: UInt64) -> UInt64 {
        let overflow = maximum == UInt64.max ? UInt64.max : maximum + 1
        return min(measure(value, remaining: overflow, depth: 0), overflow)
    }

    private static func measure(_ value: Any, remaining: UInt64, depth: Int) -> UInt64 {
        guard remaining > 0 else { return 0 }
        guard depth < 64 else { return remaining }
        if value is RuntimeEmptyPayload || value is RuntimeStateSubscription { return 0 }
        if let value = value as? String {
            return min(UInt64(value.utf8.count), remaining)
        }
        if let value = value as? Data {
            return min(UInt64(value.count), remaining)
        }
        if let value = value as? URL {
            return min(UInt64(value.absoluteString.utf8.count), remaining)
        }
        if value is Bool || value is Int8 || value is UInt8 {
            return min(1, remaining)
        }
        if value is Int16 || value is UInt16 {
            return min(2, remaining)
        }
        if value is Int32 || value is UInt32 || value is Float {
            return min(4, remaining)
        }
        if value is Int64 || value is UInt64 || value is Int || value is UInt
            || value is Double
        {
            return min(8, remaining)
        }
        if value is UUID { return min(16, remaining) }
        if value is Date { return min(8, remaining) }

        let mirror = Mirror(reflecting: value)
        guard !mirror.children.isEmpty else {
            return min(1, remaining)
        }
        var total: UInt64 = 0
        for child in mirror.children {
            total += measure(
                child.value,
                remaining: remaining - total,
                depth: depth + 1
            )
            if total >= remaining { return remaining }
        }
        return total
    }
}
