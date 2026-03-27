import AppKit
import Carbon

struct InputStatus {
    let inputSourceName: String
    let inputSourceID: String?
    let inputModeID: String?
    let inputSourceBundleID: String?
    let inputSourceIcon: NSImage?
    let capsLockOn: Bool

    var identitySignature: String {
        [
            inputSourceID ?? "nil-id",
            inputModeID ?? "nil-mode",
            inputSourceBundleID ?? "nil-bundle",
            inputSourceName
        ].joined(separator: "|")
    }

    var compactDisplayText: String {
        let normalized = inputSourceName.lowercased()

        if normalized.contains("pinyin") || inputSourceName.contains("拼音") || inputSourceName.contains("简体") || inputSourceName.contains("中文") {
            return "中"
        }

        if normalized.contains("abc") || normalized.contains("english") || normalized.contains("u.s.") || normalized.contains("us") {
            return "英"
        }

        return String(inputSourceName.prefix(2))
    }
}

final class InputSourceService {
    private var sourceIconCache: [String: NSImage] = [:]
    private var keycapIconCache: [String: NSImage] = [:]
    private var lastLoggedStatusSignature: String?

    func currentStatus() -> InputStatus {
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let sourceName = currentInputSourceName(source: source)
        let sourceID = currentInputSourceID(source: source)
        let sourceModeID = currentInputSourceModeID(source: source)
        let sourceBundleID = currentInputSourceBundleID(source: source)
        let sourceIdentityKey = [
            sourceID ?? "nil-id",
            sourceModeID ?? "nil-mode",
            sourceBundleID ?? "nil-bundle",
            sourceName
        ].joined(separator: "|")
        let sourceIcon: NSImage?
        if let cachedIcon = sourceIconCache[sourceIdentityKey] {
            sourceIcon = cachedIcon
        } else {
            let resolvedIcon = currentInputSourceIcon(
                source: source,
                inputSourceID: sourceID,
                inputModeID: sourceModeID,
                bundleID: sourceBundleID,
                sourceName: sourceName
            )
            sourceIcon = resolvedIcon
            sourceIconCache[sourceIdentityKey] = resolvedIcon
        }
        let capsLockOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        let logSignature = "\(sourceIdentityKey)|caps=\(capsLockOn)|iconLoaded=\(sourceIcon != nil)"
        if logSignature != lastLoggedStatusSignature {
            lastLoggedStatusSignature = logSignature
            DebugLogger.log(
                "current input source name=\(sourceName) id=\(sourceID ?? "nil") mode=\(sourceModeID ?? "nil") bundle=\(sourceBundleID ?? "nil") iconLoaded=\(sourceIcon != nil)"
            )
        }
        return InputStatus(
            inputSourceName: sourceName,
            inputSourceID: sourceID,
            inputModeID: sourceModeID,
            inputSourceBundleID: sourceBundleID,
            inputSourceIcon: sourceIcon,
            capsLockOn: capsLockOn
        )
    }

    private func currentInputSourceName(source: TISInputSource?) -> String {
        guard
            let source,
            let rawName = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else {
            return "Unknown Input Source"
        }

        let cfName = unsafeBitCast(rawName, to: CFString.self)
        return cfName as String
    }

    private func currentInputSourceID(source: TISInputSource?) -> String? {
        guard
            let source,
            let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else {
            return nil
        }

        return unsafeBitCast(rawID, to: CFString.self) as String
    }

    private func currentInputSourceModeID(source: TISInputSource?) -> String? {
        guard
            let source,
            let rawModeID = TISGetInputSourceProperty(source, kTISPropertyInputModeID)
        else {
            return nil
        }

        return unsafeBitCast(rawModeID, to: CFString.self) as String
    }

    private func currentInputSourceBundleID(source: TISInputSource?) -> String? {
        guard
            let source,
            let rawBundleID = TISGetInputSourceProperty(source, kTISPropertyBundleID)
        else {
            return nil
        }

        return unsafeBitCast(rawBundleID, to: CFString.self) as String
    }

    private func currentInputSourceIcon(
        source: TISInputSource?,
        inputSourceID: String?,
        inputModeID: String?,
        bundleID: String?,
        sourceName: String
    ) -> NSImage? {
        if let icon = preferredKnownInputMethodIcon(inputSourceID: inputSourceID, bundleID: bundleID, sourceName: sourceName) {
            return icon
        }

        if let icon = preferredCapsuleInputMethodIcon(inputSourceID: inputSourceID, sourceName: sourceName) {
            return icon
        }

        let candidates = matchingInputSources(
            primarySource: source,
            inputSourceID: inputSourceID,
            inputModeID: inputModeID,
            bundleID: bundleID,
            sourceName: sourceName
        )

        for candidate in candidates {
            if let icon = iconImage(for: candidate) {
                return icon
            }
        }

        for candidate in candidates {
            if let icon = bundleIcon(for: candidate) {
                return icon
            }
        }

        return fallbackInputMethodIcon(inputSourceID: inputSourceID, sourceName: sourceName)
    }

    private func matchingInputSources(
        primarySource: TISInputSource?,
        inputSourceID: String?,
        inputModeID: String?,
        bundleID: String?,
        sourceName: String
    ) -> [TISInputSource] {
        var orderedSources: [TISInputSource] = []

        if let primarySource {
            orderedSources.append(primarySource)
        }

        let allSources = (TISCreateInputSourceList(nil, false).takeRetainedValue() as? [TISInputSource]) ?? []
        for candidate in allSources {
            let candidateID = currentInputSourceID(source: candidate)
            let candidateModeID = currentInputSourceModeID(source: candidate)
            let candidateBundleID = currentInputSourceBundleID(source: candidate)
            let candidateName = currentInputSourceName(source: candidate)

            let matchesID = inputSourceID != nil && candidateID == inputSourceID
            let matchesMode = inputModeID != nil && candidateModeID == inputModeID
            let matchesBundle = bundleID != nil && candidateBundleID == bundleID
            let matchesName = candidateName == sourceName

            guard matchesID || matchesMode || matchesBundle || matchesName else { continue }
            guard orderedSources.contains(where: { CFEqual($0, candidate) }) == false else { continue }
            orderedSources.append(candidate)
        }

        return orderedSources
    }

    private func iconImageURL(for source: TISInputSource) -> URL? {
        guard let rawURL = TISGetInputSourceProperty(source, kTISPropertyIconImageURL) else {
            return nil
        }

        let imageURL = unsafeBitCast(rawURL, to: CFURL.self) as URL
        return imageURL
    }

    private func iconImage(for source: TISInputSource) -> NSImage? {
        if let imageURL = iconImageURL(for: source) {
            for candidateURL in iconCandidateURLs(for: imageURL) {
                if let image = loadImage(from: candidateURL) {
                    return prepared(image, sourceURL: candidateURL)
                }
            }

            if let appURL = enclosingApplicationURL(for: imageURL) {
                return prepared(NSWorkspace.shared.icon(forFile: appURL.path))
            }
        }

        if let iconRef = iconRef(for: source) {
            return prepared(NSImage(iconRef: iconRef))
        }

        return nil
    }

    private func iconCandidateURLs(for imageURL: URL) -> [URL] {
        var urls: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL) {
            let path = url.path
            guard seenPaths.insert(path).inserted else { return }
            urls.append(url)
        }

        let pathExtension = imageURL.pathExtension
        if pathExtension.isEmpty == false {
            let retinaName = imageURL.lastPathComponent.replacingOccurrences(of: ".\(pathExtension)", with: "@2x.\(pathExtension)")
            append(imageURL.deletingLastPathComponent().appendingPathComponent(retinaName))

            if pathExtension.lowercased() != "tiff" {
                append(imageURL.deletingPathExtension().appendingPathExtension("tiff"))
            }
        }

        append(imageURL)
        return urls
    }

    private func enclosingApplicationURL(for imageURL: URL) -> URL? {
        var currentURL = imageURL.deletingLastPathComponent()

        while currentURL.path != "/" {
            if currentURL.pathExtension == "app" {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }

            currentURL = parentURL
        }

        return nil
    }

    private func iconRef(for source: TISInputSource) -> IconRef? {
        guard let rawIconRef = TISGetInputSourceProperty(source, kTISPropertyIconRef) else {
            return nil
        }

        return OpaquePointer(rawIconRef)
    }

    private func bundleIcon(for source: TISInputSource) -> NSImage? {
        let bundleID = currentInputSourceBundleID(source: source)
        let sourceID = currentInputSourceID(source: source)
        let sourceName = currentInputSourceName(source: source)

        if let knownIcon = preferredKnownInputMethodIcon(inputSourceID: sourceID, bundleID: bundleID, sourceName: sourceName) {
            return knownIcon
        }

        guard
            let bundleID,
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let bundle = Bundle(url: appURL)
        else {
            return nil
        }

        if let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let iconPath = bundle.path(forResource: (iconFile as NSString).deletingPathExtension, ofType: (iconFile as NSString).pathExtension.isEmpty ? nil : (iconFile as NSString).pathExtension)
            if let iconPath, let image = NSImage(contentsOfFile: iconPath) {
                return prepared(image, sourceURL: URL(fileURLWithPath: iconPath))
            }
        }

        return prepared(NSWorkspace.shared.icon(forFile: appURL.path))
    }

    private func preferredKnownInputMethodIcon(inputSourceID: String?, bundleID: String?, sourceName: String) -> NSImage? {
        let normalizedID = inputSourceID?.lowercased() ?? ""
        let normalizedBundleID = bundleID?.lowercased() ?? ""
        let normalizedName = sourceName.lowercased()

        if normalizedID.contains("rime") || normalizedBundleID.contains("rime") || normalizedName.contains("rime") || sourceName.contains("鼠须管") || normalizedName.contains("squirrel") {
            let baseURL = URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app/Contents/Resources")
            let candidateURLs = [
                baseURL.appendingPathComponent("rime.pdf"),
                baseURL.appendingPathComponent("Rime.icns")
            ]

            for candidateURL in candidateURLs {
                if let image = NSImage(contentsOf: candidateURL) {
                    return prepared(image, sourceURL: candidateURL)
                }
            }

            let url = URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app")
            return prepared(NSWorkspace.shared.icon(forFile: url.path))
        }

        return nil
    }

    private func preferredCapsuleInputMethodIcon(inputSourceID: String?, sourceName: String) -> NSImage? {
        guard let systemLabel = systemLabelText(inputSourceID: inputSourceID, sourceName: sourceName) else {
            return nil
        }

        return renderedKeycapIcon(systemLabel)
    }

    private func fallbackInputMethodIcon(inputSourceID: String?, sourceName: String) -> NSImage? {
        guard let systemLabel = systemLabelText(inputSourceID: inputSourceID, sourceName: sourceName) else {
            return nil
        }

        return renderedKeycapIcon(systemLabel)
    }

    private func systemLabelText(inputSourceID: String?, sourceName: String) -> String? {
        let iconLabels: [String: String] = [
            "com.apple.keylayout.ABC": "A",
            "com.apple.keylayout.USExtended": "A",
            "com.apple.keylayout.US": "US",
            "com.apple.keylayout.USInternational-PC": "US",
            "com.apple.keylayout.British": "GB",
            "com.apple.keylayout.British-PC": "GB",
            "com.apple.keylayout.Australian": "AU",
            "com.apple.keylayout.Canadian": "CA",
            "com.apple.keylayout.Colemak": "CO",
            "com.apple.keylayout.Dvorak": "DV",
            "com.apple.keylayout.Dvorak-Left": "DV",
            "com.apple.keylayout.Dvorak-Right": "DV",
            "com.apple.keylayout.DVORAK-QWERTYCMD": "DV",
            "com.apple.keylayout.Irish": "IE",
            "com.apple.inputmethod.Korean.2SetKorean": "한",
            "com.apple.inputmethod.Korean.3SetKorean": "한",
            "com.apple.inputmethod.Korean.390Sebulshik": "한",
            "com.apple.inputmethod.Korean.GongjinCheongRomaja": "한",
            "com.apple.inputmethod.Korean.HNCRomaja": "한",
            "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese": "あ",
            "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese": "あ",
            "com.apple.inputmethod.TCIM.Cangjie": "倉",
            "com.apple.inputmethod.TCIM.Pinyin": "繁拼",
            "com.apple.inputmethod.TCIM.Shuangpin": "雙",
            "com.apple.inputmethod.TCIM.WBH": "畫",
            "com.apple.inputmethod.TCIM.Jianyi": "速",
            "com.apple.inputmethod.TCIM.Zhuyin": "注",
            "com.apple.inputmethod.TCIM.ZhuyinEten": "注",
            "com.apple.inputmethod.TYIM.Sucheng": "速",
            "com.apple.inputmethod.TYIM.Stroke": "畫",
            "com.apple.inputmethod.TYIM.Phonetic": "粤拼",
            "com.apple.inputmethod.TYIM.Cangjie": "倉",
            "com.apple.inputmethod.SCIM.WBX": "五",
            "com.apple.inputmethod.SCIM.WBH": "画",
            "com.apple.inputmethod.SCIM.Shuangpin": "双",
            "com.apple.inputmethod.SCIM.ITABC": "拼"
        ]

        if let inputSourceID, let label = iconLabels[inputSourceID] {
            return label
        }

        guard let inputSourceID, inputSourceID.lowercased().hasPrefix("com.apple.keylayout.") else {
            return nil
        }

        let trimmedName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return nil }

        return trimmedName.count == 1 ? trimmedName.uppercased() : String(trimmedName.prefix(2)).uppercased()
    }

    private func loadImage(from url: URL) -> NSImage? {
        return NSImage(contentsOf: url)
    }

    private func prepared(_ image: NSImage, sourceURL: URL? = nil) -> NSImage {
        let result = (image.copy() as? NSImage) ?? image
        result.isTemplate = shouldUseTemplate(for: result, sourceURL: sourceURL)
        return result
    }

    private func renderedKeycapIcon(_ label: String) -> NSImage? {
        if let cachedIcon = keycapIconCache[label] {
            return cachedIcon
        }

        let isMultiCharacter = label.count > 1
        let isASCIIOnly = label.unicodeScalars.allSatisfy(\.isASCII)
        let size = NSSize(width: 22, height: 16)
        let scale: CGFloat = 4
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmap else { return nil }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let keycapRect = isMultiCharacter
            ? NSRect(x: 0, y: 0, width: 22, height: 16)
            : NSRect(x: 0, y: 0, width: 22, height: 16)
        let keycapPath = NSBezierPath(roundedRect: keycapRect, xRadius: 4.2, yRadius: 4.2)
        NSColor.white.setFill()
        keycapPath.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat
        if isMultiCharacter {
            fontSize = 9.4
        } else if isASCIIOnly {
            fontSize = 11.6
        } else {
            fontSize = 10.8
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let attributedString = NSAttributedString(string: label, attributes: attributes)
        let measuredRect = attributedString.boundingRect(
            with: keycapRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let opticalYOffset: CGFloat
        if isMultiCharacter {
            opticalYOffset = -2.8
        } else if isASCIIOnly {
            opticalYOffset = -2.8
        } else {
            opticalYOffset = -3.4
        }
        let textRect = NSRect(
            x: keycapRect.minX,
            y: keycapRect.minY + floor((keycapRect.height - measuredRect.height) / 2 + opticalYOffset),
            width: keycapRect.width,
            height: keycapRect.height
        )

        attributedString.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        keycapIconCache[label] = image
        return image
    }

    private func shouldUseTemplate(for image: NSImage, sourceURL: URL?) -> Bool {
        if sourceURL?.pathExtension.lowercased() == "pdf" {
            return true
        }

        return isGrayScale(image)
    }

    private func isGrayScale(_ image: NSImage) -> Bool {
        guard let imageRef = cgImage(for: image),
              let colorSpace = imageRef.colorSpace
        else {
            return false
        }

        if colorSpace.model == .monochrome {
            return true
        }

        guard let imageData = imageRef.dataProvider?.data,
              let rawData = CFDataGetBytePtr(imageData)
        else {
            return false
        }

        let bytesPerPixel = imageRef.bitsPerPixel / max(imageRef.bitsPerComponent, 1)
        guard bytesPerPixel >= 3 else { return false }

        var byteIndex = 0
        for _ in 0 ..< imageRef.width * imageRef.height {
            let red = rawData[byteIndex]
            let green = rawData[byteIndex + 1]
            let blue = rawData[byteIndex + 2]

            if red != green || green != blue {
                return false
            }

            byteIndex += bytesPerPixel
        }

        return true
    }

    private func cgImage(for image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
