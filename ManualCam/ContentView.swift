import SwiftUI
import AVFoundation

enum CamParam: String, CaseIterable {
    case iso = "ISO", shutter = "Shutter", aperture = "Aperture"
    case wb = "W.Bal", focus = "Focus", ev = "Exp±", zoom = "Zoom"
}

struct ContentView: View {
    // Bump this on every build so you can verify the update installed
    private let appVersion = "0.1.23"
    @StateObject private var cam   = CameraManager()
    @StateObject private var store = PhotoStore()

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
    @State private var selectedParam  = CamParam.iso
    @State private var exposureMode   = ExposureMode.manual
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
    @State private var focusLocked    = false
    @State private var showGallery    = false
    @State private var shutterFlash   = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Color.black.ignoresSafeArea()
                if cam.permissionGranted {
                    ZStack() {
                        viewfinder(geo: geo)
                        controlPanel(geo: geo)
                    }
                } else {
                    permissionView
                }
            }
        }
        // .ignoresSafeArea()
        // .ignoresSafeArea(.all)
        .preferredColorScheme(.dark)
        .onAppear {
            cam.setup()
            // Wire photo callback → PhotoStore (captures localIdentifier for deletion sync)
            cam.onPhotoCaptured = { [weak store] img, localId in
                store?.add(img, localIdentifier: localId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Refresh gallery when returning to app (in case user deleted from Photos)
            store.refresh()
        }
        .onChange(of: isoIdx)     { _ in applyIfManual() }
        .onChange(of: shutterIdx) { _ in applyIfManual() }
        .onChange(of: evIdx)      { _ in cam.setEV(evValues[evIdx]) }
        .onChange(of: wbIdx)      { _ in applyWBIfManual() }
        .onChange(of: focusIdx)   { _ in applyFocusIfManual() }
        .onChange(of: zoomIdx)    { _ in cam.setZoom(zoomValues[zoomIdx]) }
        // Hook into CameraManager capturedPhotos to persist each new photo
        .onChange(of: cam.capturedPhotos.count) { _ in
            if let newest = cam.capturedPhotos.first {
                store.add(newest)
            }
        }
        .sheet(isPresented: $showGallery) { GalleryView(store: store) }
    }

    // MARK: - Viewfinder
    @ViewBuilder
    func viewfinder(geo: GeometryProxy) -> some View {

        ZStack {
            CameraPreviewView(session: cam.session)
                .gesture(MagnificationGesture()
                    .updating($pinchScale) { v,s,_ in s=v }
                    .onChanged { v in cam.setZoom((baseZoom*v).clamped(to: cam.zoomRange)) }
                    .onEnded   { [self] v in
                        let newZoom = (baseZoom*v).clamped(to: cam.zoomRange)
                        DispatchQueue.main.async {
                            baseZoom = newZoom
                            zoomIdx  = nearest(zoomValues, newZoom)
                        }
                    }
                )
                .onTapGesture { loc in
                    cam.tapToFocus(at: loc, in: CGSize(width: geo.size.width, height:  geo.size.width))
                    // cam.tapToFocus(at: loc, in: CGSize(width: geo.size.width, height: vfH))
                    focusTapPoint = loc; focusLocked = false
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.5)  { focusLocked = true }
                    DispatchQueue.main.asyncAfter(deadline: .now()+2.5)  { focusTapPoint = nil; focusLocked = false }
                }

            if showGrid { GridOverlay() }
            if let pt = focusTapPoint { FocusReticle(locked: focusLocked).position(pt) }
            if shutterFlash { Color.white.ignoresSafeArea().allowsHitTesting(false) }

            // TOP BAR
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
                        TopBarButton(icon: "arrow.triangle.2.circlepath.camera") {
                            if let next = nextCamera() { cam.switchCamera(to: next); baseZoom = 1 }
                        }
                    }
                }
                .padding(.top, geo.safeAreaInsets.top + 8)
                .padding(.horizontal, 14)
                Spacer()
            }

            // INFO PILLS
            VStack {
                Spacer().frame(height: geo.safeAreaInsets.top + 60)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        InfoPill(label:"ISO",  value:"\(Int(cam.currentISO))",            warn: cam.currentISO >= 3200)
                        InfoPill(label:"SS",   value: fmtSS(cam.currentShutterSpeed))
                        InfoPill(label:"ƒ",    value: String(format:"%.1f", apertureValues[apIdx]))
                        InfoPill(label:"WB",   value: "\(Int(cam.currentWBTemp))K")
                        InfoPill(label:"FOC",  value: String(format:"%.2f", cam.currentLensPosition))
                        InfoPill(label:"ZOOM", value: String(format:"%.1f×", cam.currentZoom))
                        if cam.supportsLiDAR    { InfoPill(label:"LiDAR", value:"ON", accent:true) }
                        if cam.supportsAppleLog { InfoPill(label:"LOG",   value:"ON", accent:true) }
                    }
                    .padding(.horizontal, 12)
                }
                Spacer()
            }

            // ZOOM BAR
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach([1.0,2.0,3.0,5.0], id:\.self) { z in
                        if z <= cam.zoomRange.upperBound + 0.5 {
                            Button {
                                cam.setZoom(z)
                                            let zi = nearest(zoomValues, z)
                                            DispatchQueue.main.async { baseZoom = z; zoomIdx = zi }
                            } label: {
                                let active = abs(cam.currentZoom - z) < 0.3
                                Text("\(Int(z))×")
                                    .font(.system(size:13, weight:.bold))
                                    .foregroundColor(active ? .yellow : .white)
                                    .padding(.horizontal,6).padding(.vertical,4)
                                    .background(Capsule()
                                        .fill(active ? Color.yellow.opacity(0.2) : Color.black.opacity(0.55))
                                        .overlay(Capsule().strokeBorder(
                                            active ? Color.yellow : Color.white.opacity(0.18), lineWidth:1)))
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
            }

            // HISTOGRAM
            if showHistogram {
                VStack {
                    Spacer().frame(height: geo.safeAreaInsets.top + 100)
                    HStack {
                        Spacer()
                        HistogramView(image: store.photos.first?.thumbnail.cgImage)
                            .frame(width:90, height:52).padding(.trailing,12)
                    }
                    Spacer()
                }
            }

            if countdownActive && countdown > 0 {
                Text("\(countdown)")
                    .font(.system(size:80, weight:.ultraLight, design:.rounded))
                    .foregroundColor(.white).shadow(radius:10)
            }

            // Version badge — bottom right of viewfinder
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(appVersion)
                        .font(.system(size:9, weight:.medium, design:.monospaced))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.trailing, 8)
                        .padding(.bottom, 6)
                }
            }
        }
        .frame(width: geo.size.width, height: geo.size.width)
        // .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Control Panel
    @ViewBuilder
    func controlPanel(geo: GeometryProxy) -> some View {
        VStack(spacing: 6) {

            // Camera selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cam.availableCameras) { info in
                        Button { cam.switchCamera(to: info); baseZoom = 1 } label: {
                            VStack(spacing: 2) {
                                Image(systemName: sfIcon(info)).font(.system(size:15))
                                Text(info.displayName).font(.system(size:10, weight:.bold))
                                Text(info.device.localizedName.components(separatedBy:" ").first ?? "")
                                    .font(.system(size:8)).foregroundColor(.gray)
                            }
                            .foregroundColor(cam.activeCamera?.id == info.id ? .yellow : .gray)
                            .frame(width:66, height:46)
                            .background(RoundedRectangle(cornerRadius:10)
                                .fill(cam.activeCamera?.id == info.id ? Color.yellow.opacity(0.08) : .clear)
                                .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(
                                    cam.activeCamera?.id == info.id ? Color.yellow : Color.white.opacity(0.07),
                                    lineWidth: cam.activeCamera?.id == info.id ? 1.5 : 1)))
                        }
                    }
                }
                .padding(.horizontal,8).padding(.vertical,8)
            }
            .frame(height:62)

            Divider().background(Color.white.opacity(0.08)).frame(height:6)

            // Mode bar
            HStack(spacing:6) {
                ForEach(ExposureMode.allCases, id:\.self) { mode in
                    Button { exposureMode = mode; applyExposureMode(mode) } label: {
                        Text(mode.rawValue)
                            .font(.system(size:11, weight:.bold)).kerning(0.4)
                            .foregroundColor(exposureMode == mode ? .black : .gray)
                            .padding(.horizontal,10).padding(.vertical,4)
                            .background(Capsule()
                                .fill(exposureMode == mode ? Color.yellow : .clear)
                                .overlay(Capsule().strokeBorder(
                                    exposureMode == mode ? Color.yellow : Color.white.opacity(0.1), lineWidth:1)))
                    }
                }
            }
            .padding(.horizontal,8).padding(.top,2).padding(.bottom,4)
            .frame(height:36)

            Divider().background(Color.white.opacity(0.08))

            // Dial cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing:6) {
                    ForEach(CamParam.allCases, id:\.self) { p in
                        Button { selectedParam = p } label: {
                            DialCard(label:p.rawValue, value:dialVal(p), unit:dialUnit(p),
                                     isSelected:selectedParam==p, isLocked:isLocked(p), showAuto:isLocked(p))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal,12).padding(.top,4).padding(.bottom,5)
            }
            .frame(height:66)

            Divider().background(Color.white.opacity(0.08))

            // Active rotary dial
            activeDial.frame(height:52)

            Divider().background(Color.white.opacity(0.08))

            HStack(alignment:.center) {
                // Gallery thumbnail
                Button { showGallery = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius:10)
                            .fill(Color(white:0.15))
                            .overlay(RoundedRectangle(cornerRadius:10)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth:1.5))
                        if let img = store.photos.first?.thumbnail {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .clipShape(RoundedRectangle(cornerRadius:8))
                        } else {
                            Image(systemName:"photo.on.rectangle")
                                .font(.system(size:20)).foregroundColor(.gray)
                        }
                    }
                    .frame(width:54, height:54)
                }

                Spacer()

                // Shutter button
                Button { triggerShutter() } label: {
                    ZStack {
                        Circle().strokeBorder(Color.white.opacity(0.28), lineWidth:3.5)
                            .frame(width:76, height:76)
                        Circle().fill(Color.white).frame(width:62, height:62)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.07), lineWidth:2))
                    }
                }
                .buttonStyle(ShutterButtonStyle())

                Spacer()

                // Format + Timer
                VStack(spacing:5) {
                    Button { rawEnabled.toggle() } label: {
                        Text(rawEnabled ? "RAW" : "HEIF")
                            .font(.system(size:11, weight:.bold))
                            .foregroundColor(rawEnabled ? .yellow : .white)
                            .frame(width:54, height:24)
                            .background(Capsule().fill(Color.white.opacity(0.08))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth:1)))
                    }
                    Button {
                        timerSeconds = [0,3,10][(([0,3,10].firstIndex(of:timerSeconds) ?? 0)+1)%3]
                    } label: {
                        HStack(spacing:3) {
                            Image(systemName:"timer").font(.system(size:11))
                            if timerSeconds > 0 { Text("\(timerSeconds)s").font(.system(size:10, weight:.bold)) }
                        }
                        .foregroundColor(timerSeconds > 0 ? .yellow : .gray)
                        .frame(width:54, height:22)
                        .background(Capsule().fill(Color.white.opacity(0.05)))
                    }
                }
            }
            .padding(.horizontal,24)
            .padding(.top,20)
            .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? geo.safeAreaInsets.bottom : 16)
            .frame(maxWidth: .infinity)
        }
        .padding(top:300)
        .background(Color.white.opacity(0))
    }

    // MARK: - Active Dial
    @ViewBuilder
    var activeDial: some View {
        if selectedParam == .iso {
            DialView(label:"ISO",     values:isoValues,      format:{ String(Int($0)) },
                     selectedIndex:$isoIdx,     isLocked:isLocked(.iso))
        } else if selectedParam == .shutter {
            DialView(label:"Shutter", values:shutterValues,  format:{ fmtSSDouble($0) },
                     selectedIndex:$shutterIdx, isLocked:isLocked(.shutter))
        } else if selectedParam == .aperture {
            DialView(label:"f-stop",  values:apertureValues, format:{ String(format:"f%.1f",$0) },
                     selectedIndex:$apIdx,      isLocked:isLocked(.aperture))
        } else if selectedParam == .wb {
            DialView(label:"K",       values:wbValues,       format:{ String(Int($0))+"K" },
                     selectedIndex:$wbIdx,      isLocked:isLocked(.wb))
        } else if selectedParam == .focus {
            DialView(label:"Focus",   values:focusValues,    format:{ $0>=0.99 ? "inf" : String(format:"%.2f",$0) },
                     selectedIndex:$focusIdx,   isLocked:isLocked(.focus))
        } else if selectedParam == .ev {
            DialView(label:"EV",      values:evValues,       format:{ $0==0 ? "0" : String(format:"%+.1f",$0) },
                     selectedIndex:$evIdx,      isLocked:isLocked(.ev))
        } else {
            DialView(label:"Zoom",    values:zoomValues,     format:{ String(format:"%.1fx",$0) },
                     selectedIndex:$zoomIdx,    isLocked:false)
        }
    }

    // MARK: - Permission
    var permissionView: some View {
        VStack(spacing:20) {
            Spacer()
            Image(systemName:"camera.aperture").font(.system(size:72)).foregroundColor(.yellow)
            Text("ManualCam").font(.system(size:28, weight:.bold))
            Text("Full manual control over every iPhone camera.")
                .font(.system(size:15)).foregroundColor(.gray)
                .multilineTextAlignment(.center).padding(.horizontal,32)
            Button("Enable Camera") { cam.setup() }
                .font(.system(size:16, weight:.bold)).foregroundColor(.black)
                .padding(.horizontal,36).padding(.vertical,14)
                .background(Color.yellow).cornerRadius(14)
            Spacer()
        }
    }

    // MARK: - Shutter
    func triggerShutter() {
        guard !countdownActive else { return }
        if timerSeconds == 0 { fireShutter(); return }
        countdownActive = true; countdown = timerSeconds
        UIImpactFeedbackGenerator(style:.medium).impactOccurred()
        Timer.scheduledTimer(withTimeInterval:1, repeats:true) { t in
            countdown -= 1
            UIImpactFeedbackGenerator(style:.light).impactOccurred()
            if countdown <= 0 { t.invalidate(); countdownActive = false; fireShutter() }
        }
    }

    func fireShutter() {
        withAnimation(.easeIn(duration:0.05)) { shutterFlash = true }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.08) {
            withAnimation(.easeOut(duration:0.35)) { shutterFlash = false }
        }
        UIImpactFeedbackGenerator(style:.heavy).impactOccurred()
        cam.capturePhoto(rawEnabled: rawEnabled)
    }

    // MARK: - Exposure helpers
    func applyIfManual() {
        guard exposureMode == .manual || exposureMode == .tv else { return }
        cam.setISO(isoValues[isoIdx]); cam.setShutterSpeed(shutterValues[shutterIdx])
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
        case .auto:   cam.setAutoExposure(); cam.setAutoWhiteBalance(); cam.setAutoFocus()
        case .manual: cam.setISO(isoValues[isoIdx]); cam.setShutterSpeed(shutterValues[shutterIdx])
                      cam.setWhiteBalanceTemp(wbValues[wbIdx]); cam.setFocus(lensPosition:focusValues[focusIdx])
        case .av:     cam.setAutoExposure(); cam.setAutoWhiteBalance()
        case .tv:     cam.setShutterSpeed(shutterValues[shutterIdx]); cam.setAutoWhiteBalance()
        case .p:      cam.setAutoExposure(); cam.setAutoWhiteBalance(); cam.setAutoFocus(); cam.setEV(evValues[evIdx])
        }
    }

    func isLocked(_ p: CamParam) -> Bool {
        switch exposureMode {
        case .manual: return false
        case .auto:   return [.iso,.shutter,.wb,.focus,.ev].contains(p)
        case .av:     return [.iso,.shutter,.wb].contains(p)
        case .tv:     return [.iso,.wb].contains(p)
        case .p:      return [.iso,.shutter,.wb,.focus].contains(p)
        }
    }

    func dialVal(_ p: CamParam) -> String {
        switch p {
        case .iso:      return "\(Int(isoValues[isoIdx]))"
        case .shutter:  return fmtSSDouble(shutterValues[shutterIdx])
        case .aperture: return "ƒ\(String(format:"%.1f",apertureValues[apIdx]))"
        case .wb:       return "\(Int(wbValues[wbIdx]))K"
        case .focus:    return focusValues[focusIdx] >= 0.99 ? "∞" : String(format:"%.2f",focusValues[focusIdx])
        case .ev:       let v=evValues[evIdx]; return v==0 ? "0" : String(format:"%+.1f",v)
        case .zoom:     return String(format:"%.1f×",zoomValues[zoomIdx])
        }
    }

    func dialUnit(_ p: CamParam) -> String {
        switch p {
        case .iso: return "sensitivity"; case .shutter: return "seconds"
        case .aperture: return "f-stop"; case .wb: return "Kelvin"
        case .focus: return "position";  case .ev: return "stops"; case .zoom: return "optical"
        }
    }

    func fmtSS(_ t: CMTime) -> String { fmtSSDouble(CMTimeGetSeconds(t)) }
    func fmtSSDouble(_ s: Double) -> String {
        if s >= 1 { return String(format:"%.0f\"",s) }
        return "1/\(Int((1.0/s).rounded()))"
    }

    func nearest(_ arr: [CGFloat], _ val: CGFloat) -> Int {
        arr.indices.min(by: { abs(arr[$0]-val) < abs(arr[$1]-val) }) ?? 0
    }

    func nextCamera() -> CameraDeviceInfo? {
        guard !cam.availableCameras.isEmpty else { return nil }
        let ci = cam.availableCameras.firstIndex(where:{ $0.id == cam.activeCamera?.id }) ?? 0
        return cam.availableCameras[(ci+1) % cam.availableCameras.count]
    }

    func sfIcon(_ info: CameraDeviceInfo) -> String {
        switch info.icon {
        case "0.5x": return "camera.aperture"
        case "1x":   return "camera"
        case "2x","3x": return "camera.viewfinder"
        case "person","face": return "person.crop.circle"
        case "lidar": return "lidar.camera"
        default:     return "camera"
        }
    }
}

// MARK: - Shutter Button Style
struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.91 : 1.0)
            .animation(.easeInOut(duration:0.08), value:configuration.isPressed)
    }
}

// MARK: - Top Bar Button
struct TopBarButton: View {
    let icon: String; var active: Bool = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName:icon).font(.system(size:16))
                .foregroundColor(active ? .black : .white)
                .frame(width:36, height:36)
                .background(Circle().fill(active ? Color.yellow : Color.black.opacity(0.5)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth:1))
        }
    }
}

// MARK: - Info Pill
struct InfoPill: View {
    let label: String; let value: String
    var warn: Bool = false; var accent: Bool = false
    var body: some View {
        HStack(spacing:3) {
            Text(label).font(.system(size:10, weight:.medium)).foregroundColor(.gray)
            Text(value).font(.system(size:11, weight:.bold, design:.monospaced))
                .foregroundColor(warn ? .red : accent ? .cyan : .white)
        }
        .padding(.horizontal,8).padding(.vertical,3)
        .background(RoundedRectangle(cornerRadius:5).fill(Color.black.opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius:5)
                .strokeBorder(warn ? Color.red.opacity(0.5) : Color.white.opacity(0.1), lineWidth:1)))
    }
}

// MARK: - Grid
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w=geo.size.width, h=geo.size.height
                p.move(to:.init(x:w/3,y:0));    p.addLine(to:.init(x:w/3,y:h))
                p.move(to:.init(x:2*w/3,y:0));  p.addLine(to:.init(x:2*w/3,y:h))
                p.move(to:.init(x:0,y:h/3));    p.addLine(to:.init(x:w,y:h/3))
                p.move(to:.init(x:0,y:2*h/3));  p.addLine(to:.init(x:w,y:2*h/3))
            }
            .stroke(Color.white.opacity(0.22), lineWidth:0.5)
        }
    }
}

// MARK: - Focus Reticle
struct FocusReticle: View {
    let locked: Bool
    @State private var scale: CGFloat = 1.3
    var body: some View {
        ZStack {
            ForEach(0..<4, id:\.self) { i in CornerBracket().rotationEffect(.degrees(Double(i)*90)) }
        }
        .frame(width:locked ? 52:70, height:locked ? 52:70)
        .foregroundColor(locked ? .cyan : .yellow)
        .scaleEffect(scale)
        .onAppear { withAnimation(.easeOut(duration:0.2)) { scale=1.0 } }
        .animation(.easeInOut(duration:0.2), value:locked)
    }
}

struct CornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to:CGPoint(x:rect.minX, y:rect.minY+13))
        p.addLine(to:CGPoint(x:rect.minX, y:rect.minY))
        p.addLine(to:CGPoint(x:rect.minX+13, y:rect.minY))
        return p
    }
}

// MARK: - Gallery View (uses PhotoStore, supports swipe-to-delete)
struct GalleryView: View {
    @ObservedObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedPhoto: PhotoStore.StoredPhoto? = nil
    let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationView {
            Group {
                if store.photos.isEmpty {
                    VStack(spacing:16) {
                        Image(systemName:"photo.on.rectangle.angled")
                            .font(.system(size:60)).foregroundColor(.gray)
                        Text("No photos yet").foregroundColor(.gray)
                        Text("Tap the shutter to start shooting")
                            .font(.system(size:13)).foregroundColor(.gray.opacity(0.6))
                    }
                    .frame(maxWidth:.infinity, maxHeight:.infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns:cols, spacing:2) {
                            ForEach(store.photos) { photo in
                                Image(uiImage: photo.thumbnail)
                                    .resizable().scaledToFill()
                                    .frame(minWidth:0, maxWidth:.infinity)
                                    .aspectRatio(1, contentMode:.fill)
                                    .clipped()
                                    .onTapGesture { selectedPhoto = photo }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle("Photos (\(store.photos.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading) {
                    Button("Refresh") { store.refresh() }.font(.system(size:13))
                }
                ToolbarItem(placement:.navigationBarTrailing) { Button("Done") { dismiss() } }
            }
            .background(Color.black)
        }
        .preferredColorScheme(.dark)
        // Full-screen photo viewer with delete
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo, store: store, onClose: { selectedPhoto = nil })
        }
    }
}

// MARK: - Photo Detail View
struct PhotoDetailView: View {
    let photo: PhotoStore.StoredPhoto
    @ObservedObject var store: PhotoStore
    let onClose: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading) {
                    Button("Close") { onClose() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement:.navigationBarTrailing) {
                    Button(role:.destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName:"trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete from App", role:.destructive) {
                store.delete(photo: photo)
                onClose()
            }
            Button("Cancel", role:.cancel) {}
        } message: {
            Text("This removes the photo from ManualCam only. It stays in your Photos library.")
        }
    }
}
