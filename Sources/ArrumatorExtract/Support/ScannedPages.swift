import ArrumatorCore

extension ExtractionConfig.PDF {
    /// The pages of a scanned document that OCR reads, 0-based and in order, of `pageCount` (at least one): all of them
    /// when there are at most `ocrAllIfAtMost`, else the first `ocrHeadPages` and the last. A PDF's image pages and a
    /// TIFF's pages are chosen by it alike.
    func ocrPages(of pageCount: Int) -> [Int] {
        guard pageCount > ocrAllIfAtMost else { return Array(0..<pageCount) }
        return Array(Set(0..<min(ocrHeadPages, pageCount)).union([pageCount - 1])).sorted()
    }
}
