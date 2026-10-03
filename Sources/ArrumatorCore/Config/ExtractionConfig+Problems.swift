extension ExtractionConfig {
    /// The limits a parser of a file is held to, which a value below one would turn into a trap or into reading
    /// nothing, and the counts of what is read (pages, entries, slides, sheets, rows, columns), which cannot be fewer
    /// than none.
    var problems: [String] {
        let limits: [(key: String, value: Int)] = [
            ("emailBodyCapBytes", emailBodyCapBytes), ("emailReadCapBytes", emailReadCapBytes),
            ("image.maxPixels", image.maxPixels), ("zipEntryCapBytes", zipEntryCapBytes), ("zipMaxEntries", zipMaxEntries),
        ]
        let counts: [(key: String, value: Int)] = [
            ("pdf.ocrHeadPages", pdf.ocrHeadPages), ("pdf.ocrAllIfAtMost", pdf.ocrAllIfAtMost),
            ("archiveMaxEntries", archiveMaxEntries), ("pptxMaxSlides", pptxMaxSlides),
            ("xlsx.maxSheets", xlsx.maxSheets), ("xlsx.maxRows", xlsx.maxRows), ("xlsx.maxColumns", xlsx.maxColumns),
            ("emailForwardsRead", emailForwardsRead),
        ]
        // The vision model's own deadline: at 0 a description would wait as long as the client does, which is for ever.
        let deadline = image.vlmTimeout > 0 ? [] : ["extraction.image.vlmTimeout must be more than 0"]
        return limits.filter { $0.value < 1 }.map { "extraction.\($0.key) must be at least 1" }
            + counts.filter { $0.value < 0 }.map { "extraction.\($0.key) cannot be negative" } + deadline
    }
}
