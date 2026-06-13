import SwiftUI
import AVFoundation

// MARK: - Histogram View
struct HistogramView: View {
    let image: CGImage?

    @State private var rBins: [Float] = Array(repeating: 0, count: 64)
    @State private var gBins: [Float] = Array(repeating: 0, count: 64)
    @State private var bBins: [Float] = Array(repeating: 0, count: 64)

    var body: some View {
        Canvas { ctx, size in
            let w    = size.width
            let h    = size.height
            let binW = w / CGFloat(rBins.count)

            for (bins, color): ([Float], Color) in [(bBins, .blue), (rBins, .red), (gBins, .green)] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h))
                for (i, v) in bins.enumerated() {
                    let x = CGFloat(i) * binW
                    let y = h - CGFloat(v) * h * 0.9
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
                ctx.fill(path, with: .color(color.opacity(0.45)))
            }
        }
        .background(Color.black.opacity(0.55))
        .cornerRadius(6)
        // FIX: use iOS 16-compatible onChange(of:perform:)
        .onChange(of: image) { newImage in
            if let img = newImage {
                Task.detached(priority: .utility) {
                    let (r, g, b) = Self.computeHistogram(from: img)
                    await MainActor.run {
                        self.rBins = r
                        self.gBins = g
                        self.bBins = b
                    }
                }
            }
        }
    }

    static func computeHistogram(from image: CGImage) -> ([Float], [Float], [Float]) {
        let bins = 64
        var rBins = [Float](repeating: 0, count: bins)
        var gBins = [Float](repeating: 0, count: bins)
        var bBins = [Float](repeating: 0, count: bins)

        let thumbW = 128, thumbH = 96
        let bytesPerRow = thumbW * 4
        guard let ctx = CGContext(
            data: nil, width: thumbW, height: thumbH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (rBins, gBins, bBins) }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        guard let data = ctx.data else { return (rBins, gBins, bBins) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: thumbW * thumbH * 4)

        let total = Float(thumbW * thumbH)
        for i in 0..<thumbW * thumbH {
            let r = pixels[i * 4]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            rBins[Int(r) * bins / 256] += 1 / total
            gBins[Int(g) * bins / 256] += 1 / total
            bBins[Int(b) * bins / 256] += 1 / total
        }

        let overall = Swift.max(rBins.max() ?? 1, Swift.max(gBins.max() ?? 1, bBins.max() ?? 1))
        if overall > 0 {
            rBins = rBins.map { $0 / overall }
            gBins = gBins.map { $0 / overall }
            bBins = bBins.map { $0 / overall }
        }
        return (rBins, gBins, bBins)
    }
}
