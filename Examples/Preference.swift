struct Preference: Sendable {
    // Temp
    static nonisolated(unsafe) var `default` = Preference()

    var uri: String? = "rtmp://192.168.11.221/live"
    var streamName: String? = "live"
}
