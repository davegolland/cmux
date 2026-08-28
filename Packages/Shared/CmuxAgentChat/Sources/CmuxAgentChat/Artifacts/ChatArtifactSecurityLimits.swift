import Foundation

/// Bounds for transcript-derived artifact discovery.
///
/// Transcript text is mutable input. These limits keep path extraction and
/// filesystem canonicalization proportional to the useful gallery size, even
/// when one line contains a large number of valid-looking path fields.
enum ChatArtifactSecurityLimits {
    /// Maximum UTF-8 bytes for one path token retained by the index.
    static let maxPathBytes = 4 * 1024

    /// Maximum unique paths extracted from one structured JSON value.
    static let maxPathsPerValue = 512

    /// Maximum supplemental occurrences carried by one parser batch.
    static let maxReferencesPerBatch = 4_096

    /// Maximum canonical path rows retained by one derived gallery snapshot.
    static let maxIndexedReferences = 4_096
}
