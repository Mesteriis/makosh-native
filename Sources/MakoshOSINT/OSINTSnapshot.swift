import Foundation

/// What the interface shows: settings, connection, open attempts, last runs, sketches, server keys, the last install.
public struct OSINTSnapshot: Equatable, Sendable {
    public var settings: OSINTSettings
    public var connected: Bool
    public var openAttempts: [OSINTAttempt]
    public var lastRuns: [UUID: OSINTRun]
    public var sketches: [UUID: OSINTSketchLink]
    public var serverKeyNames: Set<String>
    public var lastInstall: OSINTInstall?
    public var installing: Bool
    public var lastFailure: OSINTFailure?

    public init(
        settings: OSINTSettings, connected: Bool, openAttempts: [OSINTAttempt] = [], lastRuns: [UUID: OSINTRun] = [:],
        sketches: [UUID: OSINTSketchLink] = [:], serverKeyNames: Set<String> = [], lastInstall: OSINTInstall? = nil,
        installing: Bool = false,
        lastFailure: OSINTFailure? = nil
    ) {
        self.settings = settings
        self.connected = connected
        self.openAttempts = openAttempts
        self.lastRuns = lastRuns
        self.sketches = sketches
        self.serverKeyNames = serverKeyNames
        self.lastInstall = lastInstall
        self.installing = installing
        self.lastFailure = lastFailure
    }
}
