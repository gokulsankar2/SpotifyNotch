//
//  AlbumColorExtractor.swift
//  SpotifyNotch
//
//  Pulls a three-colour palette out of raw album-art bytes, off the main
//  actor. Takes `Data` rather than `NSImage` so nothing non-Sendable has to
//  cross an actor boundary, and so decoding can be capped: the artwork is
//  thumbnailed straight out of the image source and never rasterised at
//  native resolution.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

actor AlbumColorExtractor {

    static let shared = AlbumColorExtractor()

    // MARK: - Tuning

    /// Side of the square we quantise. 32x32 = 1024 samples, which is ample for
    /// a dominant-colour histogram and costs a fraction of a millisecond.
    private static let sampleSide = 32
    /// Levels per channel in the histogram: 6^3 = 216 buckets.
    private static let levels = 6
    /// The overlay sits on the pure-black hardware notch, so anything below
    /// this luminance reads as invisible and gets lifted.
    private static let minimumLuminance = 0.38
    /// Accents may sit darker than the dominant colour, but not by much.
    private static let accentMinimumLuminance = 0.24
    /// Two buckets closer than this in RGB space count as the same colour.
    private static let separation = 0.20
    private static let cacheLimit = 24

    // MARK: - State

    private var cache: [Int: AlbumPalette] = [:]
    private var recency: [Int] = []
    private var ciContext: CIContext?

    init() {}

    // MARK: - Entry point

    /// Never throws and never traps: malformed or undecodable bytes yield
    /// `AlbumPalette.fallback`.
    func palette(from imageData: Data) async -> AlbumPalette {
        guard !imageData.isEmpty else { return .fallback }

        let key = Self.cacheKey(for: imageData)
        if let hit = cache[key] {
            touch(key)
            return hit
        }

        let palette = extract(from: imageData)
        store(palette, for: key)
        return palette
    }

    func clearCache() {
        cache.removeAll()
        recency.removeAll()
    }

    // MARK: - Extraction

    private func extract(from data: Data) -> AlbumPalette {
        guard let thumbnail = Self.thumbnail(from: data, maxPixel: Self.sampleSide * 2) else {
            return .fallback
        }
        guard let pixels = Self.rasterise(thumbnail, side: Self.sampleSide) else {
            return areaAveragePalette(from: data) ?? .fallback
        }

        let candidates = Self.dominantColours(in: pixels, side: Self.sampleSide)
        guard let base = candidates.first else {
            return areaAveragePalette(from: data) ?? .fallback
        }
        return Self.assemble(base: base, accents: Array(candidates.dropFirst()))
    }

    /// Coarse RGB histogram. A flat average over the whole cover collapses to
    /// mud, so buckets are scored by population *weighted by saturation*: a
    /// smaller vivid bucket beats a large desaturated one.
    private static func dominantColours(in pixels: [UInt8], side: Int) -> [RGBColor] {
        let bucketCount = levels * levels * levels
        var counts = [Int](repeating: 0, count: bucketCount)
        var sumR = [Double](repeating: 0, count: bucketCount)
        var sumG = [Double](repeating: 0, count: bucketCount)
        var sumB = [Double](repeating: 0, count: bucketCount)

        let pixelCount = side * side
        pixels.withUnsafeBufferPointer { buffer in
            guard buffer.count >= pixelCount * 4 else { return }
            for index in 0..<pixelCount {
                let offset = index * 4
                let alpha = Double(buffer[offset + 3])
                guard alpha > 8 else { continue }

                // The bitmap is premultipliedLast; recover straight components.
                let red = Double(buffer[offset]) / alpha
                let green = Double(buffer[offset + 1]) / alpha
                let blue = Double(buffer[offset + 2]) / alpha

                let qr = min(levels - 1, Int(red * Double(levels)))
                let qg = min(levels - 1, Int(green * Double(levels)))
                let qb = min(levels - 1, Int(blue * Double(levels)))
                let bucket = (qr * levels + qg) * levels + qb

                counts[bucket] += 1
                sumR[bucket] += red
                sumG[bucket] += green
                sumB[bucket] += blue
            }
        }

        var scored: [(score: Double, colour: RGBColor)] = []
        scored.reserveCapacity(32)
        // Buckets below the floor are resampling fringe between two real
        // colours. A very busy cover can scatter everything below it, so drop
        // the floor to 1 rather than come back empty-handed.
        for floor in [max(3, pixelCount / 256), 1] {
            for bucket in 0..<bucketCount where counts[bucket] >= floor {
                let population = Double(counts[bucket])
                let colour = RGBColor(red: sumR[bucket] / population,
                                      green: sumG[bucket] / population,
                                      blue: sumB[bucket] / population)

                let high = max(colour.red, max(colour.green, colour.blue))
                let low = min(colour.red, min(colour.green, colour.blue))
                let saturation = high > 0 ? (high - low) / high : 0
                let luminance = colour.luminance

                let tonal: Double
                if luminance < 0.06 {
                    tonal = 0.10          // letterboxing / black backgrounds
                } else if luminance > 0.94 {
                    tonal = 0.22          // blown-out whites
                } else {
                    tonal = 1.0
                }

                // Population is damped to a fractional power so a large flat
                // backdrop cannot simply out-vote a smaller vivid region; a
                // muddy grey covering 90% of a cover is the worst possible tint.
                let weight = (0.10 + pow(saturation, 0.6) * 3.4) * tonal
                scored.append((pow(population, 0.6) * weight, colour))
            }
            if !scored.isEmpty { break }
        }

        scored.sort { $0.score > $1.score }

        var picked: [RGBColor] = []
        for entry in scored {
            guard picked.allSatisfy({ distance($0, entry.colour) > separation }) else { continue }
            picked.append(entry.colour)
            if picked.count == 3 { break }
        }
        return picked
    }

    private static func assemble(base: RGBColor, accents: [RGBColor]) -> AlbumPalette {
        let primary = legible(base, minimum: minimumLuminance)
        let secondaryRaw = accents.first ?? primary.adjustingBrightness(by: 0.68)
        let tertiaryRaw = accents.dropFirst().first ?? primary.adjustingBrightness(by: 1.45)

        return AlbumPalette(
            primary: primary,
            secondary: legible(secondaryRaw, minimum: accentMinimumLuminance),
            tertiary: legible(tertiaryRaw, minimum: minimumLuminance)
        )
    }

    /// Lifts a colour until it clears `minimum` luminance. Repeated multiplies
    /// clip toward white, which desaturates gracefully rather than banding, so
    /// even a near-black cover still produces a visible waveform.
    private static func legible(_ colour: RGBColor, minimum: Double) -> RGBColor {
        var result = colour
        guard result.luminance > 0.004 else {
            return RGBColor(red: 0.72, green: 0.72, blue: 0.74)
        }

        var passes = 0
        while result.luminance < minimum, passes < 4 {
            let factor = min(3.0, minimum / max(result.luminance, 0.01))
            let lifted = result.adjustingBrightness(by: factor)
            if lifted == result { break }
            result = lifted
            passes += 1
        }

        if result.luminance > 0.97 {
            result = result.adjustingBrightness(by: 0.88)
        }
        return result
    }

    private static func distance(_ lhs: RGBColor, _ rhs: RGBColor) -> Double {
        let dr = lhs.red - rhs.red
        let dg = lhs.green - rhs.green
        let db = lhs.blue - rhs.blue
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    // MARK: - Decoding

    private static func thumbnail(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func rasterise(_ image: CGImage, side: Int) -> [UInt8]? {
        let bytesPerRow = side * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * side)

        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: side,
                                          height: side,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? buffer : nil
    }

    // MARK: - Fallback

    /// Cheaper path used only when the histogram pass cannot run: three
    /// `CIAreaAverage` samples across the cover. Muddier, but always yields
    /// something tinted rather than dropping to Spotify green.
    private func areaAveragePalette(from data: Data) -> AlbumPalette? {
        guard let image = CIImage(data: data) else { return nil }
        let extent = image.extent
        guard extent.width >= 3, extent.height >= 3, extent.isInfinite == false else { return nil }

        let context = sharedCIContext()
        let third = extent.width / 3
        let regions = [
            CGRect(x: extent.minX, y: extent.minY, width: third, height: extent.height),
            CGRect(x: extent.minX + third, y: extent.minY, width: third, height: extent.height),
            CGRect(x: extent.minX + third * 2, y: extent.minY, width: third, height: extent.height)
        ]

        var samples: [RGBColor] = []
        for region in regions {
            guard let colour = Self.averageColour(of: image, in: region, context: context) else { continue }
            samples.append(colour)
        }
        guard let base = samples.first else { return nil }
        return Self.assemble(base: base, accents: Array(samples.dropFirst()))
    }

    private static func averageColour(of image: CIImage,
                                      in rect: CGRect,
                                      context: CIContext) -> RGBColor? {
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image,
                                                 kCIInputExtentKey: CIVector(cgRect: rect)]),
              let output = filter.outputImage else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output,
                           toBitmap: base,
                           rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        return RGBColor(red: Double(bytes[0]) / 255,
                        green: Double(bytes[1]) / 255,
                        blue: Double(bytes[2]) / 255)
    }

    private func sharedCIContext() -> CIContext {
        if let ciContext { return ciContext }
        let created = CIContext(options: [.useSoftwareRenderer: false])
        ciContext = created
        return created
    }

    // MARK: - Cache

    /// Album art is 50-300 KB, so hashing every byte would dwarf the extraction
    /// itself. Length plus the head and tail is enough to tell covers apart.
    private static func cacheKey(for data: Data) -> Int {
        var hasher = Hasher()
        hasher.combine(data.count)
        hasher.combine(data.prefix(96))
        hasher.combine(data.suffix(96))
        return hasher.finalize()
    }

    private func store(_ palette: AlbumPalette, for key: Int) {
        cache[key] = palette
        touch(key)
        while recency.count > Self.cacheLimit {
            let evicted = recency.removeFirst()
            cache[evicted] = nil
        }
    }

    private func touch(_ key: Int) {
        if let existing = recency.firstIndex(of: key) {
            recency.remove(at: existing)
        }
        recency.append(key)
    }
}
