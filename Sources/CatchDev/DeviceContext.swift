import Foundation

/// Best-effort device / app context collected at submit time. Foundation-only so
/// it compiles and unit-tests on every platform (the values are most meaningful on
/// a real iOS device — the Simulator reports the host architecture for `deviceModel`).
enum DeviceContext {
    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var appBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Hardware identifier, e.g. `iPhone15,2`.
    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { rawBuffer -> String in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine
    }

    static var locale: String {
        Locale.current.identifier
    }

    /// IANA timezone identifier, e.g. `America/New_York`.
    static var timezone: String {
        TimeZone.current.identifier
    }

    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "unknown"
        #endif
    }
}
