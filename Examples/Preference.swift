struct Preference: Sendable {
    // Temp
    static nonisolated(unsafe) var `default` = Preference()

    var uri: String? = "rtmp://127.0.0.1:1935/live"
    var streamName: String? = "live"
}
