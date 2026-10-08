import Foundation

/// The watchers of Incoming and of the archive: when a file has stopped changing, and what is never taken in.
public struct WatcherConfig: Sendable, Codable, Hashable {
    public var fsEventsLatency: Double
    public var stabilityPollInterval: Double
    public var stabilityRequiredPolls: Int
    public var zeroByteWaitSeconds: Double
    /// How long a file that came or changed, in Incoming or in the archive, is waited for to stop changing before History
    /// says it is taking long, once; it is waited for still, looked at every `awayPollSeconds`, and taken once it stops
    /// (`Settling`).
    public var stabilityMaxWaitSeconds: Double
    /// How long a file that has stopped changing but cannot be opened, as when its permissions keep the app from reading
    /// it, is waited for before the watcher stops waiting and, for Incoming, History says so; it is taken up again once
    /// it can be opened or it changes.
    public var unopenableWaitSeconds: Double
    /// The most items a package may hold to be taken as one document, in Incoming or in the archive; one that holds more,
    /// such as a photo library, is not walked further, and is left, as one that cannot be opened is, saying why.
    public var maxPackageItems: Int
    /// How often, while the archive's folder is not there, the app looks whether it is back, as FSEvents need not say so;
    /// and how often a file taking long (`stabilityMaxWaitSeconds`) is looked at.
    public var awayPollSeconds: Double
    public var ignoredNamePrefixes: [String]
    public var ignoredNames: [String]
    public var ignoredExtensions: [String]
    public var ignoredNameSubstrings: [String]
    /// Prefix + extension of the archive's record files (`_documents.md`, `_labels.md`, history files), and of those
    /// earlier versions left, which are never read as documents.
    public var managedFilePrefix: String
    public var managedFileExtension: String
    /// What a document's sidecar is named by: the document's file name with this after it, as
    /// `2026-07-05 EDP - Fatura julho.pdf.arrumator.md` beside `2026-07-05 EDP - Fatura julho.pdf`. A file whose name ends
    /// with it is the app's own, never taken in as a document, and no document is given such a name.
    public var sidecarSuffix: String
    /// How long the archive watcher waits for the event of one of the app's own file operations, which it leaves out; the
    /// first event for the path uses the wait up (must exceed FSEvents latency).
    public var selfChangeTTLSeconds: Double
}
