import AppKit
import Vision

enum TextExtraction {
    enum ExtractionError: Error { case invalidRegion }

    static func image(from source: CGImage, region: CGRect?) throws -> CGImage {
        guard let region else { return source }
        guard region.origin.x.isFinite, region.origin.y.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.width > 0, region.height > 0 else { throw ExtractionError.invalidRegion }
        let selection = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !selection.isEmpty, !selection.isNull else { throw ExtractionError.invalidRegion }
        let pixels = CGRect(x: selection.minX * CGFloat(source.width), y: (1 - selection.maxY) * CGFloat(source.height),
                            width: selection.width * CGFloat(source.width), height: selection.height * CGFloat(source.height)).integral
        guard pixels.width >= 2, pixels.height >= 2, let cropped = source.cropping(to: pixels) else { throw ExtractionError.invalidRegion }
        return cropped
    }

    static func recognize(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func mergingLines(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
