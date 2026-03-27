import AppKit

struct IconGenerator {
    let capsOnSourceURL: URL
    let capsOffSourceURL: URL
    let assetsURL: URL
    let baseResourcesURL: URL

    private let appIconSpecs: [(name: String, points: Int, scale: Int)] = [
        ("icon_16x16.png", 16, 1),
        ("icon_16x16@2x.png", 16, 2),
        ("icon_32x32.png", 32, 1),
        ("icon_32x32@2x.png", 32, 2),
        ("icon_128x128.png", 128, 1),
        ("icon_128x128@2x.png", 128, 2),
        ("icon_256x256.png", 256, 1),
        ("icon_256x256@2x.png", 256, 2),
        ("icon_512x512.png", 512, 1),
        ("icon_512x512@2x.png", 512, 2)
    ]

    func run() throws {
        let capsOnImage = try loadImage(at: capsOnSourceURL)
        let capsOffImage = try loadImage(at: capsOffSourceURL)

        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseResourcesURL, withIntermediateDirectories: true)

        try writePNG(capsOnImage, to: baseResourcesURL.appending(path: "status-icon-caps-on.png"))
        try writePNG(capsOffImage, to: baseResourcesURL.appending(path: "status-icon-caps-off.png"))
        try writePNG(capsOnImage, to: baseResourcesURL.appending(path: "app-icon-caps-on.png"))
        try writePNG(capsOffImage, to: baseResourcesURL.appending(path: "app-icon-caps-off.png"))

        let appIconSetURL = assetsURL.appending(path: "AppIcon.appiconset")
        try FileManager.default.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)

        for spec in appIconSpecs {
            let pixelSize = spec.points * spec.scale
            let resized = try resizedImage(capsOnImage, size: NSSize(width: pixelSize, height: pixelSize))
            try writePNG(resized, to: appIconSetURL.appending(path: spec.name))
        }

        try appIconContentsJSON().write(to: appIconSetURL.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
        try assetCatalogContentsJSON().write(to: assetsURL.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
    }

    private func loadImage(at url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else {
            throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to load source image at \(url.path)."])
        }
        return image
    }

    private func resizedImage(_ image: NSImage, size: NSSize) throws -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        defer { output.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        return output
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        guard
            let tiffData = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiffData),
            let pngData = rep.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "IconGenerator", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to export PNG for \(url.lastPathComponent)."])
        }

        try pngData.write(to: url)
    }

    private func appIconContentsJSON() -> String {
        """
        {
          "images" : [
            { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
            { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
            { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
            { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
            { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
            { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
            { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
            { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
            { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
            { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
    }

    private func assetCatalogContentsJSON() -> String {
        """
        {
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    fputs("Usage: generate_icons.swift <caps_on_png> <caps_off_png> <assets_xcassets_dir> <resources_dir>\n", stderr)
    exit(1)
}

let generator = IconGenerator(
    capsOnSourceURL: URL(fileURLWithPath: arguments[1]),
    capsOffSourceURL: URL(fileURLWithPath: arguments[2]),
    assetsURL: URL(fileURLWithPath: arguments[3]),
    baseResourcesURL: URL(fileURLWithPath: arguments[4])
)

do {
    try generator.run()
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
