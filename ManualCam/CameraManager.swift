import AVFoundation
import UIKit
import Photos
import Combine

// MARK: - Camera Device Info
struct CameraDeviceInfo: Identifiable, Equatable {
    let id: String
    let device: AVCaptureDevice
    var displayName: String
    var icon: String

    static func == (lhs: CameraDeviceInfo, rhs: CameraDeviceInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Capture Mode
enum CaptureMode: String, CaseIterable {
    case photo = "PHOTO"
    case video = "VIDEO"
    case raw   = "RAW"
}

// MARK: - Exposure Mode
enum ExposureMode: String, CaseIterable {
    case auto   = "AUTO"
    case manual = "MANUAL"
    case av     = "Av"
    case tv     = "Tv"
    case p      = "P"
}

// MARK: - CameraManager
@MainActor
final class CameraManager: NSObject, ObservableObject {

    // Session
    let session = AVCaptureSession()
    private var videoInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.manualcam.session", qos: .userInitiated)

    // Published state
    @Published var availableCameras: [CameraDeviceInfo] = []
    @Published var activeCamera: CameraDeviceInfo?
    @Published var captureMode: CaptureMode = .photo
    @Published var exposureMode: ExposureMode = .manual

    // Real camera values (read back from device)
    @Published var currentISO: Float = 400
    @Published var currentShutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 125)
    @Published var currentLensPosition: Float = 1.0    // 0..1
    @Published var currentEV: Float = 0
    @Published var currentZoom: CGFloat = 1.0
    @Published var currentWBGains: AVCaptureDevice.WhiteBalanceGains?
    @Published var currentWBTemp: Float = 5500

    // Capability ranges (populated per device)
    @Published var isoRange: ClosedRange<Float> = 50...6400
    @Published var shutterRange: ClosedRange<Double> = (1.0/8000)...(1.0/4)
    @Published var evRange: ClosedRange<Float> = -3...3
    @Published var zoomRange: ClosedRange<CGFloat> = 1...10
    @Published var minFocusDist: Float = 0
    @Published var supportsRAW: Bool = false
    @Published var supportsAppleLog: Bool = false
    @Published var supportsLiDAR: Bool = false
    @Published var supportsTorch: Bool = false

    // UI state
    @Published var isTorchOn: Bool = false
    @Published var isRecording: Bool = false
    @Published var lastPhoto: UIImage?
    @Published var focusPoint: CGPoint? = nil
    @Published var permissionGranted: Bool = false
    @Published var errorMessage: String? = nil

    // Histogram data
    @Published var histogram: [Float] = Array(repeating: 0, count: 64)

    private var kvoTokens: [NSKeyValueObservation] = []
    private var histogramTimer: Timer?

    // MARK: - Setup
    func setup() {
        Task {
            await checkPermissions()
        }
    }

    private func checkPermissions() async {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch videoStatus {
        case .authorized:
            permissionGranted = true
            await configureSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionGranted = granted
            if granted { await configureSession() }
        default:
            permissionGranted = false
        }
    }

    private func configureSession() async {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Discover all cameras
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .builtInTelephotoCamera,
                    .builtInUltraWideCamera,
                    .builtInDualCamera,
                    .builtInDualWideCamera,
                    .builtInTripleCamera,
                    .builtInTrueDepthCamera,
                    .builtInLiDARDepthCamera,
                ],
                mediaType: .video,
                position: .unspecified
            )

            let cameras: [CameraDeviceInfo] = discovery.devices.map { device in
                var name: String
                var icon: String
                switch device.deviceType {
                case .builtInUltraWideCamera:    name = "Ultra Wide"; icon = "0.5x"
                case .builtInWideAngleCamera:    name = device.position == .front ? "Front" : "Wide"; icon = device.position == .front ? "person" : "1x"
                case .builtInTelephotoCamera:    name = "Telephoto"; icon = "3x"
                case .builtInDualCamera:         name = "Dual"; icon = "2x"
                case .builtInDualWideCamera:     name = "Dual Wide"; icon = "2x"
                case .builtInTripleCamera:       name = "Triple"; icon = "3x"
                case .builtInLiDARDepthCamera:   name = "LiDAR Wide"; icon = "lidar"
                case .builtInTrueDepthCamera:    name = "TrueDepth"; icon = "face"
                default:                          name = "Camera"; icon = "camera"
                }
                return CameraDeviceInfo(id: device.uniqueID, device: device, displayName: name, icon: icon)
            }

            Task { @MainActor in
                self.availableCameras = cameras
            }

            // Start with back wide camera
            let preferred = discovery.devices.first(where: {
                $0.deviceType == .builtInWideAngleCamera && $0.position == .back
            }) ?? discovery.devices.first

            if let device = preferred {
                self.switchToDevice(device)
            }

            // Add photo output
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
                if #available(iOS 16.0, *) {
                    self.photoOutput.maxPhotoDimensions = .init(width: 4032, height: 3024)
                }
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    // MARK: - Switch Camera
    func switchCamera(to info: CameraDeviceInfo) {
        sessionQueue.async { [weak self] in
            self?.switchToDevice(info.device)
        }
        Task { @MainActor in
            activeCamera = info
        }
    }

    private func switchToDevice(_ device: AVCaptureDevice) {
        session.beginConfiguration()

        // Remove old input
        if let old = videoInput {
            session.removeInput(old)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
        } catch {
            Task { @MainActor in self.errorMessage = error.localizedDescription }
            session.commitConfiguration()
            return
        }

        session.commitConfiguration()

        Task { @MainActor in
            self.updateCapabilities(for: device)
            self.startKVO(for: device)
        }
    }

    // MARK: - Capabilities
    private func updateCapabilities(for device: AVCaptureDevice) {
        isoRange    = device.activeFormat.minISO...device.activeFormat.maxISO
        shutterRange = CMTimeGetSeconds(device.activeFormat.minExposureDuration)...CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        evRange     = device.minExposureTargetBias...device.maxExposureTargetBias
        zoomRange   = 1.0...min(device.activeFormat.videoMaxZoomFactor, 10.0)
        minFocusDist = device.minimumFocusDistance
        supportsTorch = device.hasTorch
        supportsLiDAR = device.deviceType == .builtInLiDARDepthCamera

        // RAW support
        supportsRAW = photoOutput.availableRawPhotoPixelFormatTypes.count > 0

        // Apple Log (iPhone 15 Pro+)
        if #available(iOS 17.0, *) {
            supportsAppleLog = device.formats.contains { $0.isAppleLogVideoSupported }
        }

        // Read current values
        currentISO          = device.iso
        currentShutterSpeed = device.exposureDuration
        currentLensPosition = device.lensPosition
        currentZoom         = device.videoZoomFactor

        let tGain = device.deviceWhiteBalanceGains
        let temp  = device.temperatureAndTintValues(for: tGain)
        currentWBTemp = temp.temperature
    }

    // MARK: - KVO (live readout)
    private func startKVO(for device: AVCaptureDevice) {
        kvoTokens.forEach { $0.invalidate() }
        kvoTokens = []

        kvoTokens.append(device.observe(\.iso, options: .new) { [weak self] d, _ in
            Task { @MainActor in self?.currentISO = d.iso }
        })
        kvoTokens.append(device.observe(\.exposureDuration, options: .new) { [weak self] d, _ in
            Task { @MainActor in self?.currentShutterSpeed = d.exposureDuration }
        })
        kvoTokens.append(device.observe(\.lensPosition, options: .new) { [weak self] d, _ in
            Task { @MainActor in self?.currentLensPosition = d.lensPosition }
        })
        kvoTokens.append(device.observe(\.videoZoomFactor, options: .new) { [weak self] d, _ in
            Task { @MainActor in self?.currentZoom = d.videoZoomFactor }
        })
        kvoTokens.append(device.observe(\.deviceWhiteBalanceGains, options: .new) { [weak self] d, _ in
            Task { @MainActor in
                let gains = d.deviceWhiteBalanceGains
                self?.currentWBGains = gains
                let temp = d.temperatureAndTintValues(for: gains)
                self?.currentWBTemp = temp.temperature
            }
        })
    }

    // MARK: - Manual Controls

    func setISO(_ iso: Float) {
        guard let device = videoInput?.device else { return }
        let clamped = iso.clamped(to: isoRange)
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.setExposureModeCustom(
                duration: device.exposureDuration,
                iso: clamped,
                completionHandler: nil
            )
            device.unlockForConfiguration()
        }
    }

    func setShutterSpeed(_ seconds: Double) {
        guard let device = videoInput?.device else { return }
        let clamped = seconds.clamped(to: shutterRange)
        let duration = CMTimeMakeWithSeconds(clamped, preferredTimescale: 1_000_000)
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.setExposureModeCustom(
                duration: duration,
                iso: device.iso,
                completionHandler: nil
            )
            device.unlockForConfiguration()
        }
    }

    func setEV(_ ev: Float) {
        guard let device = videoInput?.device else { return }
        let clamped = ev.clamped(to: evRange)
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setWhiteBalanceTemp(_ kelvin: Float) {
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            var gains = device.deviceWhiteBalanceGains(for:
                AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
            )
            // Clamp gains to max
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain   = min(max(gains.redGain,   1.0), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
            gains.blueGain  = min(max(gains.blueGain,  1.0), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setAutoWhiteBalance() {
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
    }

    func setFocus(lensPosition: Float) {
        guard let device = videoInput?.device else { return }
        let clamped = lensPosition.clamped(to: 0...1)
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setAutoFocus() {
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
    }

    func tapToFocus(at point: CGPoint, in viewSize: CGSize) {
        guard let device = videoInput?.device else { return }
        // Convert from view coordinates to device coordinates (0..1)
        let devicePoint = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        focusPoint = point

        sessionQueue.async {
            try? device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        }

        // Clear reticle after a moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.focusPoint = nil
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = videoInput?.device else { return }
        let clamped = factor.clamped(to: zoomRange)
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        }
        currentZoom = clamped
    }

    func setTorch(_ on: Bool) {
        guard let device = videoInput?.device, device.hasTorch else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
        isTorchOn = on
    }

    func setAutoExposure() {
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            try? device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Photo Capture
    func capturePhoto(rawEnabled: Bool = false) {
        let settings: AVCapturePhotoSettings

        if rawEnabled, let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            let processedFormat: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc
            ]
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat,
                processedFormat: processedFormat
            )
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }

        settings.isHighResolutionPhotoEnabled = true
        settings.flashMode = isTorchOn ? .on : .off

        // Enable depth if available
        if photoOutput.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = true
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - Photo Capture Delegate
extension CameraManager: AVCapturePhotoCaptureDelegate {

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            Task { @MainActor in self.errorMessage = error.localizedDescription }
            return
        }

        // Save to Photos library
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                // Save RAW + HEIF pair if available
                if let rawData = photo.fileDataRepresentation() {
                    // For RAW: save as DNG
                    if photo.isRawPhoto {
                        request.addResource(with: .alternatePhoto, data: rawData, options: nil)
                    } else {
                        request.addResource(with: .photo, data: rawData, options: nil)
                    }
                }
            }
        }

        // Update preview thumbnail
        if let data = photo.fileDataRepresentation(), let img = UIImage(data: data) {
            Task { @MainActor in
                self.lastPhoto = img
            }
        }
    }
}

// MARK: - Comparable clamping helpers
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
