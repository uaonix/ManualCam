import SwiftUI

// MARK: - Generic Rotary Dial
struct DialView<T: BinaryFloatingPoint>: View {
    let label: String
    let values: [T]
    let format: (T) -> String
    @Binding var selectedIndex: Int
    var isLocked: Bool = false
    var accentColor: Color = .yellow

    // sensitivity: pixels per tick (lower = faster, higher = slower)
    // 1.0 = fast, 1.5 = medium, 3.0 = slow
    private let tickSpacing: CGFloat = 28
    private let sensitivity: CGFloat = 1.5

    @State private var startIndex: Int = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isLocked ? Color.gray : accentColor)
                .frame(width: 2)
                .allowsHitTesting(false)
            tickStrip
        }
        .frame(height: 52)
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard !isLocked else { return }
                    // Use total translation from gesture start (not delta)
                    // so there's no accumulation bug
                    let totalDrag = -value.translation.width
                    let steps     = Int(totalDrag / (tickSpacing * sensitivity))
                    let newIdx    = clamp(startIndex + steps)
                    if newIdx != selectedIndex {
                        selectedIndex = newIdx
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .onEnded { _ in
                    startIndex = selectedIndex
                }
        )
        .opacity(isLocked ? 0.4 : 1.0)
        .allowsHitTesting(!isLocked)
        .onAppear { startIndex = selectedIndex }
        .onChange(of: selectedIndex) { _ in startIndex = selectedIndex }
    }

    private func clamp(_ idx: Int) -> Int {
        Swift.max(0, Swift.min(values.count - 1, idx))
    }

    private var tickStrip: some View {
        GeometryReader { geo in
            let center   = geo.size.width / 2
            let count    = values.count
            let visible  = Int(geo.size.width / tickSpacing) + 6

            Canvas { ctx, size in
                let cur      = selectedIndex
                let startIdx = Swift.max(0, cur - visible / 2)
                let endIdx   = Swift.min(count - 1, cur + visible / 2)

                for i in startIdx...endIdx {
                    let offset = CGFloat(i - cur) * tickSpacing + center
                    guard offset > -tickSpacing, offset < size.width + tickSpacing else { continue }

                    let isCurrent = i == cur
                    let isMajor   = i % 5 == 0
                    let h: CGFloat = isCurrent ? 28 : isMajor ? 20 : 12
                    let w: CGFloat = isCurrent ? 2.5 : 1.5
                    let color: Color = isCurrent ? accentColor
                        : isMajor  ? .white.opacity(0.55) : .white.opacity(0.22)

                    let rect = CGRect(x: offset - w/2, y: size.height - h - 8, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))

                    if isCurrent || isMajor {
                        let text = format(values[i])
                        let font: Font = isCurrent
                            ? .system(size: 11, weight: .bold)
                            : .system(size: 9,  weight: .medium)
                        let resolved = ctx.resolve(
                            Text(text).font(font)
                                .foregroundColor(isCurrent ? accentColor : .gray)
                        )
                        let sz = resolved.measure(in: CGSize(width: 80, height: 20))
                        ctx.draw(resolved, at: CGPoint(x: offset - sz.width/2, y: 4))
                    }
                }
            }
        }
    }
}

// MARK: - Dial Card
struct DialCard: View {
    let label: String
    let value: String
    let unit: String
    var isSelected: Bool = false
    var isLocked: Bool   = false
    var showAuto: Bool   = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 9, weight: .bold)).kerning(0.8)
                    .foregroundColor(.gray).textCase(.uppercase)
                Text(value)
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .foregroundColor(isSelected ? .yellow : .white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 8)).foregroundColor(.gray)
            }
            .padding(.top, 0)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)

            if showAuto {
                Text("A")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.cyan)
                    .padding(.top, 3)
                    .padding(.trailing, 4)
            }
        }
        .frame(width: 70, height: 46)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                    isSelected ? Color.yellow : Color.white.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 1))
        )
        .opacity(isLocked ? 0.4 : 1.0)
    }
}
