import SwiftUI
import AVFoundation

// MARK: - Parameter enum
enum CamParam: String, CaseIterable {
    case iso      = "ISO"
    case shutter  = "Shutter"
    case aperture = "Aperture"
    case wb       = "W.Bal"
    case focus    = "Focus"
    case ev       = "Exp±"
    case zoom     = "Zoom"
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var cam = CameraManager()

    let isoValues:      [Float]   = [50,64,80,100,125,160,200,250,320,400,500,640,800,1000,1250,1600,2000,2500,3200,4000,6400,12800,25600]
    let shutterValues:  [Double]  = [30,15,8,4,2,1,0.5,0.25,0.125,1/15.0,1/30.0,1/60.0,1/125.0,1/250.0,1/500.0,1/1000.0,1/2000.0,1/4000.0,1/8000.0]
    let apertureValues: [Float]   = [1.0,1.2,1.4,1.8,2.0,2.4,2.8,3.5,4.0,4.5,5.6,6.3,8,10,11,16,22]
    let wbValues:       [Float]   = [2000,2500,3000,3500,4000,4500,5000,5500,6000,6500,7000,7500,8000,10000]
    let focusValues:    [Float]   = [0,0.05,0.1,0.15,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0]
    let evValues:       [Float]   = [-3,-2.7,-2.3,-2,-1.7,-1.3,-1,-0.7,-0.3,0,0.3,0.7,1,1.3,1.7,2,2.3,2.7,3]
    let zoomValues:     [CGFloat] = [1,1.2,1.5,2,2.5,3,4,5,6,8,10]

    @State private var isoIdx     = 9
    @State private var shutterIdx = 12
    @State private var apIdx      = 6
    @State private var wbIdx      = 7
    @State private var focusIdx   = 12
    @State private var evIdx      = 9
    @State private var zoomIdx    = 0

    @State private var selectedParam:  CamParam      = .iso
    @State private var exposureMode:   ExposureMode  = .manual

    @State private var showGrid       = false
    @State private var showHistogram  = false
    @State private var torchOn        = false
    @State private var rawEnabled     = false
    @State private var timerSeconds   = 0
    @State private var countdown      = 0
    @State private var countdownActive = false

    @GestureState private var pinchScale: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0

    @State private var focusTapPoint: CGPoint? = nil
    @State private var focusLocked   = false

    @State private var showGallery     = false
    @State private var shutterFlash    = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if cam.permissionGranted {
                    VStack(spacing: 0) {
                        viewfinderArea(geo: geo)
                        controlPanel(geo: geo)
                    }
                } else {
                    permissionView
                }
            }
        }
        // Ignore BOTH edges so we control all insets ourselves
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear { cam.setup() }
        .onChange(of: isoIdx)     { _ in applyIfManual() }
        .onChange(of: shutterIdx) { _ in applyIfManual() }
        .onChange(of: evIdx)      { _ in cam.setEV(evValues[evIdx]) }
        .onChange(of: wbIdx)      { _ in applyWBIfManual() }
        .onChange(of: focusIdx)   { _ in applyFocusIfManual() }
        .onChange(of: zoomIdx)    { _ in cam.setZoom(zoomValues[zoomIdx]) }
        .sheet(isPresented: $showGallery) { GalleryView(images: cam.capturedPhotos) }
    }

    // MARK: - Viewfinder
    // Takes exactly what's left after the control panel
    @ViewBuilder
    func viewfinderArea(geo: GeometryProxy) -> some View {
        let controlH = controlPanelHeight(geo: geo)
        let vfH = geo.size.height - controlH

        ZStack {
            CameraPreviewView(session: cam.session)
                .gesture(
                    MagnificationGesture()
                        .updating($pinchScale) { val, state, _ in state = val }
                        .onChanged { val in
                            cam.setZoom((baseZoom * val).clamped(to: cam.zoomRange))
                        }
                        .onEnded { val in
                            baseZoom = (baseZoom * val).clamped(to: cam.zoomRange)
                            let z = baseZoom
                            zoomIdx = zoomValues.indices.min(by: { abs(zoomValues[$0]-z) < abs(zoomValues[$1]-z) }) ?? 0
                        }
                )
                .onTapGesture { location in
                    cam.tapToFocus(at: location, in: CGSize(width: geo.size.width, height: vfH))
                    focusTapPoint = location
                    focusLocked = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focusLocked = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { focusTapPoint = nil; focusLocked = false }
                }

            if showGrid { GridOverlay() }

            if let pt = focusTapPoint {
                FocusReticle(locked: focusLocked).position(pt)
            }

            if shutterFlash {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }

            // Top bar — sits at the very top including under status bar
            topBar(safeTop: geo.safeAreaInsets.top)

            // Info pills — just below top bar
            infoPills(safeTop: geo.safeAreaInsets.top)

            if showHistogram {
                VStack {
                    Spacer().frame(height: geo.safeAreaInsets.top + 100)
                    HStack {
                        Spacer()
                        HistogramView(image: cam.lastPhoto?.cgImage)
                            .frame(width: 90, height: 52)
                            .padding(.trailing, 12)
                    }
                    Spacer()
                }
            }

            VStack {
                Spacer()
                zoomBar.padding(.bottom, 10)
            }

            if countdownActive && countdown > 0 {
                Text("\(countdown)")
                    .font(.system(size: 80, weight: .ultraLight, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(radius: 10)
            }
        }
        .frame(width: geo.size.width, height: vfH)
        .clipped()
    }

    // MARK: - Control Panel height calculation
    // Fixed heights for each row so we can pre-calculate
    func controlPanelHeight(geo: GeometryProxy) -> CGFloat {
        let safeBottom = geo.safeAreaInsets.bottom
        // camSelector: 70, modebar: 42, dialCards: 78, dial: 52, shutter: 94 + safeBottom
        return 70 + 42 + 78 + 52 + 1 + 94 + safeBottom
    }

    // MARK: - Top Bar
    func topBar(safeTop: CGFloat) -> some View {
        VStack {
            HStack {
                TopBarButton(icon: showGrid ? "grid.circle.fill" : "grid", active: showGrid) { showGrid.toggle() }
                Spacer()
                HStack(spacing: 10) {
                    TopBarButton(icon: "waveform", active: showHistogram) { showHistogram.toggle() }
                    if cam.supportsTorch {
                        TopBarButton(icon: torchOn ? "bolt.fill" : "bolt.slash", active: torchOn) {
                            torchOn.toggle(); cam.setTorch(torchOn)
                        }
                    }
                    TopBarButton(icon: "arrow.triangle.2.circlepath.camera", active: false) {
                        if let next = nextCamera() { cam.switchCamera(to: next) }
                    }
                }
            }
            // Respect safe area top (status bar / Dynamic Island)
            .padding(.top, safeTop + 8)
            .padding(.horizontal, 14)
            Spacer()
        }
    }

    func nextCamera() -> CameraDeviceInfo? {
        guard !cam.availableCameras.isEmpty else { return nil }
        let ci = cam.availableCameras.firstIndex(where: { $0.id == cam.activeCamera?.id }) ?? 0
        return cam.availableCameras[(ci + 1) % cam.availableCameras.count]
    }

    // MARK: - Info Pills
    func infoPills(safeTop: CGFloat) -> some View {
        VStack {
            Spacer().frame(height: safeTop + 56)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    InfoPill(label: "ISO",  value: String(Int(cam.currentISO)),  warn: cam.currentISO >= 3200)
                    InfoPill(label: "SS",   value: formatShutter(cam.currentShutterSpeed))
                    InfoPill(label: "ƒ",    value: String(format: "%.1f", apertureValues[apIdx]))
                    InfoPill(label: "WB",   value: "\(Int(cam.currentWBTemp))K")
                    InfoPill(label: "FOC",  value: String(format: "%.2f", cam.currentLensPosition))
                    InfoPill(label: "ZOOM", value: String(format: "%.1f×", cam.currentZoom))
                    if cam.supportsLiDAR    { InfoPill(label: "LiDAR", value: "ON", accent: true) }
                    if cam.supportsAppleLog { InfoPill(label: "LOG",   value: "ON", accent: true) }
                }
                .padding(.horizontal, 12)
            }
            Spacer()
        }
    }

    // MARK: - Zoom Bar
    var zoomBar: some View {
        HStack(spacing: 6) {
            ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { z in
                if z <= cam.zoomRange.upperBound + 0.5 {
                    Button {
                        cam.setZoom(z); baseZoom = z
                        zoomIdx = zoomValues.indices.min(by: { abs(zoomValues[$0]-z) < abs(zoomValues[$1]-z) }) ?? 0
                    } label: {
                        Text("\(Int(z))×")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(abs(cam.currentZoom - z) < 0.3 ? .yellow : .white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(abs(cam.currentZoom - z) < 0.3 ? Color.yellow.opacity(0.2) : Color.black.opacity(0.55))
                                    .overlay(Capsule().strokeBorder(
                                        abs(cam.currentZoom - z) < 0.3 ? Color.yellow : Color.white.opacity(0.18),
                                        lineWidth: 1))
                            )
                    }
                }
            }
        }
    }

    // MARK: - Control Panel
    @ViewBuilder
    func controlPanel(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {

            // ── Camera selector ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cam.availableCameras) { info in
                        Button {
                            cam.switchCamera(to: info)
                            baseZoom = 1.0
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: sfIcon(for: info))
                                    .font(.system(size: 16))
                                Text(info.displayName)
                                    .font(.system(size: 10, weight: .bold))
                                Text(info.device.localizedName.components(separatedBy: " ").first ?? "")
                                    .font(.system(size: 8))
                                    .foregroundColor(.gray)
                            }
                            .foregroundColor(cam.activeCamera?.id == info.id ? .yellow : .gray)
                            .frame(width: 68, height: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(cam.activeCamera?.id == info.id ? Color.yellow.opacity(0.08) : Color.clear)
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                                        cam.activeCamera?.id == info.id ? Color.yellow : Color.white.opacity(0.07),
                                        lineWidth: cam.activeCamera?.id == info.id ? 1.5 : 1))
                            )
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 70)

            Divider().background(Color.white.opacity(0.08))

            // ── Mode bar ──
            HStack(spacing: 4) {
                ForEach(ExposureMode.allCases, id: \.self) { mode in
                    Button {
                        exposureMode = mode
                        applyExposureMode(mode)
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: .bold)).kerning(0.5)
                            .foregroundColor(exposureMode == mode ? .black : .gray)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(exposureMode == mode ? Color.yellow : Color.clear)
                                    .overlay(Capsule().strokeBorder(
                                        exposureMode == mode ? Color.yellow : Color.white.opacity(0.1), lineWidth: 1))
                            )
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(height: 42)

            Divider().background(Color.white.opacity(0.08))

            // ── Dial cards ──
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(CamParam.allCases, id: \.self) { param in
                        Button { selectedParam = param } label: {
                            DialCard(
                                label: param.rawValue,
                                value: dialDisplayValue(param),
                                unit: dialUnit(param),
                                isSelected: selectedParam == param,
                                isLocked: isLocked(param),
                                showAuto: isLocked(param)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 78)

            Divider().background(Color.white.opacity(0.08))

            // ── Rotary dial ──
            activeDial.frame(height: 52)

            Divider().background(Color.white.opacity(0.08))

            // ── Shutter row ──
            HStack {
                // Gallery thumb
                Button { showGallery = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Color(white: 0.15))
                            .overlay(RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5))
                        if let img = cam.capturedPhotos.first {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        } else {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 20)).foregroundColor(.gray)
                        }
                    }
                    .frame(width: 56, height: 56)
                }

                Spacer()

                // Shutter button
                Button { triggerShutter() } label: {
                    ZStack {
                        Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 3.5)
                            .frame(width: 78, height: 78)
                        Circle().fill(Color.white).frame(width: 64, height: 64)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 2))
                    }
                }
                .buttonStyle(ShutterButtonStyle())

                Spacer()

                // Right controls
                VStack(spacing: 6) {
                    Button { rawEnabled.toggle() } label: {
                        Text(rawEnabled ? "RAW" : "HEIF")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(rawEnabled ? .yellow : .white)
                            .frame(width: 56, height: 26)
                            .background(Capsule().fill(Color.white.opacity(0.08))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)))
                    }
                    Button {
                        timerSeconds = [0,3,10][(([0,3,10].firstIndex(of: timerSeconds) ?? 0) + 1) % 3]
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "timer").font(.system(size: 11))
                            if timerSeconds > 0 { Text("\(timerSeconds)s").font(.system(size: 10, weight: .bold)) }
                        }
                        .foregroundColor(timerSeconds > 0 ? .yellow : .gray)
                        .frame(width: 56, height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            // CRITICAL: pad bottom by safe area so shutter clears the home indicator
            .padding(.bottom, geo.safeAreaInsets.bottom + 8)
            .frame(height: 94 + geo.safeAreaInsets.bottom)
        }
        .background(Color(white: 0.07))
    }

    // MARK: - Active Dial
    var activeDial: some View {
        Group {
            switch selectedParam {
            case .iso:
                DialView(label: "ISO", values: isoValues, format: { String(Int($0)) }, selectedIndex: $isoIdx, isLocked: isLocked(.iso))
            case .shutter:
                DialView(label: "Shutter", values: shutterValues, format: { formatShutterDouble($0) }, selectedIndex: $shutterIdx, isLocked: isLocked(.shutter))
            case .aperture:
                DialView(label: "ƒ-stop", values: apertureValues, format: { String(format: "ƒ%.1f", $0) }, selectedIndex: $apIdx, isLocked: isLocked(.aperture))
            case .wb:
                DialView(label: "K", values: wbValues, format: { String(Int($0)) + "K" }, selectedIndex: $wbIdx, isLocked: isLocked(.wb))
            case .focus:
                DialView(label: "Focus", values: focusValues, format: { $0 >= 0.99 ? "∞" : String(format: "%.2f", $0) }, selectedIndex: $focusIdx, isLocked: isLocked(.focus))
            case .ev:
                DialView(label: "EV", values: evValues, format: { $0 == 0 ? "0" : String(format: "%+.1f", $0) }, selectedIndex: $evIdx, isLocked: isLocked(.ev))
            case .zoom:
                DialView(label: "Zoom", values: zoomValues, format: { String(format: "%.1f×", $0) }, selectedIndex: $zoomIdx, isLocked: false)
            }
        }
    }

    // MARK: - Permission View
    var permissionView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "camera.aperture").font(.system(size: 72)).foregroundColor(.yellow)
            Text("ManualCam").font(.system(size: 28, weight: .bold))
            Text("Full manual control over every iPhone camera.\nISO · Shutter · Focus · White Balance · RAW")
                .font(.system(size: 15)).foregroundColor(.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Enable Camera") { cam.setup() }
                .font(.system(size: 16, weight: .bold)).foregroundColor(.black)
                .padding(.horizontal, 36).padding(.vertical, 14)
                .background(Color.yellow).cornerRadius(14)
            Spacer()
        }
    }

    // MARK: - Shutter logic
    func triggerShutter() {
        guard !countdownActive else { return }
        if timerSeconds == 0 { fireShutter(); return }
        countdownActive = true; countdown = timerSeconds
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            countdown -= 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if countdown <= 0 { timer.invalidate(); countdownActive = false; fireShutter() }
        }
    }

    func fireShutter() {
        withAnimation(.easeIn(duration: 0.05))  { shutterFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.35)) { shutterFlash = false }
        }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        cam.capturePhoto(rawEnabled: rawEnabled)
        // Gallery thumbnail and capturedPhotos array are updated automatically
        // by the photo delegate in CameraManager — no race condition
    }

    // MARK: - Apply controls
    func applyIfManual() {
        guard exposureMode == .manual || exposureMode == .tv else { return }
        cam.setISO(isoValues[isoIdx])
        cam.setShutterSpeed(shutterValues[shutterIdx])
    }
    func applyWBIfManual() {
        guard exposureMode == .manual else { return }
        cam.setWhiteBalanceTemp(wbValues[wbIdx])
    }
    func applyFocusIfManual() {
        guard exposureMode == .manual else { return }
        cam.setFocus(lensPosition: focusValues[focusIdx])
    }
    func applyExposureMode(_ mode: ExposureMode) {
        switch mode {
        case .auto:
            cam.setAutoExposure(); cam.setAutoWhiteBalance(); cam.setAutoFocus()
        case .manual:
            cam.setISO(isoValues[isoIdx]); cam.setShutterSpeed(shutterValues[shutterIdx])
            cam.setWhiteBalanceTemp(wbValues[wbIdx]); cam.setFocus(lensPosition: focusValues[focusIdx])
        case .av:
            cam.setAutoExposure(); cam.setAutoWhiteBalance()
        case .tv:
            cam.setShutterSpeed(shutterValues[shutterIdx]); cam.setAutoWhiteBalance()
        case .p:
            cam.setAutoExposure(); cam.setAutoWhiteBalance(); cam.setAutoFocus()
            cam.setEV(evValues[evIdx])
        }
    }

    // MARK: - Helpers
    func isLocked(_ param: CamParam) -> Bool {
        switch exposureMode {
        case .manual: return false
        case .auto:   return [.iso,.shutter,.wb,.focus,.ev].contains(param)
        case .av:     return [.iso,.shutter,.wb].contains(param)
        case .tv:     return [.iso,.wb].contains(param)
        case .p:      return [.iso,.shutter,.wb,.focus].contains(param)
        }
    }

    func dialDisplayValue(_ param: CamParam) -> String {
        switch param {
        case .iso:      return String(Int(isoValues[isoIdx]))
        case .shutter:  return formatShutterDouble(shutterValues[shutterIdx])
        case .aperture: return "ƒ\(String(format: "%.1f", apertureValues[apIdx]))"
        case .wb:       return "\(Int(wbValues[wbIdx]))K"
        case .focus:    return focusValues[focusIdx] >= 0.99 ? "∞" : String(format: "%.2f", focusValues[focusIdx])
        case .ev:       let v = evValues[evIdx]; return v == 0 ? "0" : String(format: "%+.1f", v)
        case .zoom:     return String(format: "%.1f×", zoomValues[zoomIdx])
        }
    }

    func dialUnit(_ param: CamParam) -> String {
        switch param {
        case .iso: return "sensitivity"; case .shutter: return "seconds"
        case .aperture: return "f-stop"; case .wb: return "Kelvin"
        case .focus: return "position";  case .ev: return "stops"; case .zoom: return "optical"
        }
    }

    func formatShutter(_ t: CMTime) -> String { formatShutterDouble(CMTimeGetSeconds(t)) }
    func formatShutterDouble(_ s: Double) -> String {
        if s >= 1 { return String(format: "%.0f\"", s) }
        return "1/\(Int((1.0/s).rounded()))"
    }

    func sfIcon(for info: CameraDeviceInfo) -> String {
        switch info.icon {
        case "0.5x":        return "camera.aperture"
        case "1x":          return "camera"
        case "2x","3x":     return "camera.viewfinder"
        case "person","face": return "person.crop.circle"
        case "lidar":       return "lidar.camera"
        default:            return "camera"
        }
    }
}

// MARK: - Shutter Button Style
struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.91 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Top Bar Button
struct TopBarButton: View {
    let icon: String; var active: Bool = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16))
                .foregroundColor(active ? .black : .white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(active ? Color.yellow : Color.black.opacity(0.5)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
    }
}

// MARK: - Info Pill
struct InfoPill: View {
    let label: String; let value: String
    var warn: Bool = false; var accent: Bool = false
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundColor(.gray)
            Text(value).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(warn ? .red : accent ? .cyan : .white)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(warn ? Color.red.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)))
    }
}

// MARK: - Grid Overlay
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                path.move(to: .init(x: w/3, y: 0));   path.addLine(to: .init(x: w/3, y: h))
                path.move(to: .init(x: 2*w/3, y: 0)); path.addLine(to: .init(x: 2*w/3, y: h))
                path.move(to: .init(x: 0, y: h/3));   path.addLine(to: .init(x: w, y: h/3))
                path.move(to: .init(x: 0, y: 2*h/3)); path.addLine(to: .init(x: w, y: 2*h/3))
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
    }
}

// MARK: - Focus Reticle
struct FocusReticle: View {
    let locked: Bool
    @State private var scale: CGFloat = 1.2
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                CornerBracket().rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .frame(width: locked ? 52 : 70, height: locked ? 52 : 70)
        .foregroundColor(locked ? .cyan : .yellow)
        .scaleEffect(scale)
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { scale = 1.0 } }
        .animation(.easeInOut(duration: 0.25), value: locked)
    }
}

struct CornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + 12))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + 12, y: rect.minY))
        return p
    }
}

// MARK: - Gallery View
struct GalleryView: View {
    let images: [UIImage]
    @Environment(\.dismiss) var dismiss
    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        NavigationView {
            ScrollView {
                if images.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 60)).foregroundColor(.gray)
                        Text("No photos yet").foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(images.indices, id: \.self) { i in
                            Image(uiImage: images[i]).resizable().scaledToFill()
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .aspectRatio(1, contentMode: .fill).clipped()
                        }
                    }
                }
            }
            .navigationTitle("Photos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .background(Color.black)
        }
        .preferredColorScheme(.dark)
    }
}
