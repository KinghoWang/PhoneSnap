import AppKit
import NaturalLanguage
import Vision

enum PrivacyKind: String, CaseIterable {
    case phone = "电话", email = "邮箱", identity = "证件", account = "账号"
    case name = "姓名", address = "地址", secret = "凭据"
    case face = "人脸", code = "二维码", avatar = "头像候选"
}

struct PrivacyRegion {
    let rect: CGRect
    let kind: PrivacyKind
}

enum PrivacyDetector {
    static func kinds(in text: String) -> Set<PrivacyKind> {
        let rules: [(PrivacyKind, String)] = [
            (.email, #"[A-Z0-9._%+-]+\s*@\s*[A-Z0-9.-]+\.[A-Z]{2,}"#),
            (.phone, #"(?<!\d)(?:\+?86[-\s]?)?1[3-9](?:[-\s]?\d){9}(?!\d)|\+\d[\d\s()-]{7,}\d|(?:电话|手机|联系号码|phone|tel)\s*[:：]?\s*\d"#),
            (.identity, #"身份证|证件号|护照|passport|(?<!\d)\d{17}[\dX](?!\d)"#),
            (.account, #"银行卡|银行账号|卡号|账户|account\s*(?:no|number)|(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#),
            (.name, #"姓名|收件人|联系人|持卡人|收货人|(?:full|first|last)\s*name|[\p{Han}]{1,4}(?:先生|女士)"#),
            (.address, #"地址|住址|收货地|address|[\p{Han}]{2,}(?:省|市|区|县)[\p{Han}\d]{2,}(?:路|街|巷|镇|村)|[\p{Han}]{2,}(?:路|街|巷)\s*\d+\s*号"#),
            (.secret, #"密码|口令|验证码|恢复码|私钥|ap[il1][_ -]?key|access[_ -]?token|authorization|bearer\s+|password|secret|cookie|private\s+key|[?&](?:token|key|code|secret)=|sk-[A-Za-z0-9_-]{12,}"#)
        ]
        var found = Set(rules.compactMap { kind, pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil ? nil : kind
        })
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if tag == .personalName { found.insert(.name) }
            return true
        }
        return found
    }

    static func isAvatarCandidate(_ rect: CGRect, imageSize: CGSize) -> Bool {
        let width = rect.width * imageSize.width
        let height = rect.height * imageSize.height
        guard height > 0 else { return false }
        let aspect = width / height
        return (0.72...1.38).contains(aspect) && width >= 20
            && width <= min(imageSize.width, imageSize.height) * 0.22
            && (rect.minX < 0.22 || rect.maxX > 0.78)
    }

    static func detect(in image: CGImage) throws -> [PrivacyRegion] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        textRequest.usesLanguageCorrection = false
        let faces = VNDetectFaceRectanglesRequest()
        let codes = VNDetectBarcodesRequest()
        codes.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]
        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.05
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.015
        rectangles.maximumObservations = 64
        rectangles.minimumConfidence = 0.5
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([textRequest, faces, codes, rectangles])

        let observations = textRequest.results ?? []
        var result: [PrivacyRegion] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let categories = kinds(in: text)
            for kind in categories {
                result.append(PrivacyRegion(rect: padded(observation.boundingBox), kind: kind))
            }
            if !categories.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 12 {
                for neighbor in observations where neighbor !== observation {
                    let box = neighbor.boundingBox
                    let label = observation.boundingBox
                    let sameRow = abs(box.midY - label.midY) < max(box.height, label.height) * 0.65
                        && box.minX >= label.maxX && box.minX - label.maxX < 0.2
                    let nextRow = label.minY >= box.maxY && label.minY - box.maxY < label.height * 1.2
                        && abs(box.minX - label.minX) < 0.08
                    if sameRow || nextRow, let kind = categories.sorted(by: { $0.rawValue < $1.rawValue }).first {
                        result.append(PrivacyRegion(rect: padded(box), kind: kind))
                    }
                }
            }
        }
        for face in faces.results ?? [] {
            let box = face.boundingBox
            result.append(PrivacyRegion(rect: clipped(box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.35)), kind: .face))
        }
        for code in codes.results ?? [] {
            result.append(PrivacyRegion(rect: padded(code.boundingBox), kind: .code))
        }
        let size = CGSize(width: image.width, height: image.height)
        for rectangle in rectangles.results ?? [] where isAvatarCandidate(rectangle.boundingBox, imageSize: size) {
            result.append(PrivacyRegion(rect: padded(rectangle.boundingBox), kind: .avatar))
        }
        return result.filter { !$0.rect.isEmpty && !$0.rect.isNull }
    }

    private static func padded(_ rect: CGRect) -> CGRect {
        clipped(rect.insetBy(dx: max(0.003, rect.height * 0.12) * -1, dy: max(0.003, rect.height * 0.16) * -1))
    }

    private static func clipped(_ rect: CGRect) -> CGRect {
        rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

extension GrabbitDocument {
    func flattenedForSharing(displayWidth: CGFloat = 0) -> NSImage? {
        let renderedImage = rendered(displayWidth: displayWidth)
        guard let base = renderedImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.setShouldAntialias(false)
        for shape in shapes where shape.shapeType == .rectangle && shape.borderWeight == 0 && shape.fillColor.alphaComponent == 1 {
            context.setFillColor(shape.fillColor.cgColor)
            context.fill(CGRect(x: shape.rect.minX * CGFloat(base.width), y: shape.rect.minY * CGFloat(base.height),
                                width: shape.rect.width * CGFloat(base.width), height: shape.rect.height * CGFloat(base.height)).integral)
        }
        guard let result = context.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }

    func addPrivacyRegions(_ regions: [CGRect], pixelated: Bool = false, color: NSColor = .black, intensity: CGFloat = 80) {
        guard !regions.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        for region in regions {
            let clipped = region.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            if pixelated {
                addBlurRegion(BlurRegion(zOrder: nextZOrder(), rect: clipped, intensity: intensity, style: .pixelate))
            } else {
                let opaque = color.withAlphaComponent(1)
                addShape(Shape(zOrder: nextZOrder(), rect: clipped, shapeType: .rectangle,
                               borderWeight: 0, borderColor: opaque, fillColor: opaque))
            }
        }
        undoManager?.setActionName("隐私遮挡")
        undoManager?.endUndoGrouping()
    }

    func changeRedaction(id: UUID, pixelated: Bool, color: NSColor, intensity: CGFloat) {
        let shape = shapes.first { $0.id == id && $0.borderWeight == 0 && $0.fillColor.alphaComponent == 1 }
        let blur = blurRegions.first { $0.id == id }
        guard let rect = shape?.rect ?? blur?.rect, let order = shape?.zOrder ?? blur?.zOrder else { return }
        undoManager?.beginUndoGrouping()
        if shape != nil { removeShape(id: id) }
        if blur != nil { removeBlurRegion(id: id) }
        if pixelated {
            addBlurRegion(BlurRegion(id: id, zOrder: order, rect: rect, intensity: intensity, style: .pixelate))
        } else {
            let opaque = color.withAlphaComponent(1)
            addShape(Shape(id: id, zOrder: order, rect: rect, shapeType: .rectangle,
                           borderWeight: 0, borderColor: opaque, fillColor: opaque))
        }
        undoManager?.setActionName("更改打码样式")
        undoManager?.endUndoGrouping()
    }
}
