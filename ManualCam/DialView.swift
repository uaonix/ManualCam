import SwiftUI

// MARK: - Generic Rotary Dial
struct DialView<T: BinaryFloatingPoint>: View {
    let label: String
    let values: [T]
    let format: (T) -> String
    @Binding var selectedIndex: Int
    var isLocked: Bool = false
    var accentColor: Color = .yellow

    // FIX 3: much larger divisor = slower, more precise scrolling
    // Old value was tickSpacing (28) — now 3× slower
    private let tickSpacing: CGFloat = 28
    private let sensitivity: CGFloat = 3.0   // drag pixels per tick step

    @State private var dragAccum: CGFloat = 0  // accumulated drag
    @State private var lastIndex: Int = 0      // index at drag start

    var body: some View {
        ZStack {
            // Center indicator line (drawn on top)
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
                    // FIX 3: accumulate drag and only step when threshold crossed
                    let delta = -value.translation.width
                    let steps = Int((dragAccum + delta) / (tickSpacing * sensitivity))
                    if steps != 0 {
                        dragAccum += delta - CGFloat(steps) * tickSpacing * sensitivity
                        let newIdx = clamp(lastIndex + steps)
                        if newIdx != selectedIndex {
                            selectedIndex = newIdx
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    } else {
                        dragAccum += delta
                    }
                    lastIndex = selectedIndex
                    dragAccum = 0
                }
                .onEnded { _ in
                    dragAccum = 0
                    lastIndex = selectedIndex
                }
        )
        .opacity(isLocked ? 0.4 : 1.0)
        .allowsHitTesting(!isLocked)
        .onAppear { lastIndex = selectedIndex }
        .onChange(of: selectedIndex) { _ in lastIndex = selectedIndex }
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
        VStack(spacing: 2) {
            if showAuto {
                Text("A")
                    .font(.system(size: 8, weight: .black)).foregroundColor(.cyan)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
            } else {
                Spacer().frame(height: 10)
            }
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
        .frame(width: 70, height: 62)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                    isSelected ? Color.yellow : Color.white.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 1))
        )
        .opacity(isLocked ? 0.4 : 1.0)
    }
}
