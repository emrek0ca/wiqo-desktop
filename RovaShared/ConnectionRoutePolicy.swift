public enum RovaConnectionRoutePolicy {
    /// A cellular path cannot reach a Mac's remembered LAN endpoint. Prefer the existing
    /// authenticated backend relay immediately instead of entering a local reconnect loop.
    public static func shouldPreferRelay(isPaired: Bool, pathUsesCellular: Bool) -> Bool {
        isPaired && pathUsesCellular
    }

    /// Relay probing is a fallback, never a second concurrent probe or a replacement for a live
    /// direct or relay connection.
    public static func shouldProbeRelay(
        isPaired: Bool,
        directConnected: Bool,
        relayConnected: Bool,
        probeInFlight: Bool
    ) -> Bool {
        isPaired && !directConnected && !relayConnected && !probeInFlight
    }
}
