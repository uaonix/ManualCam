import AVFoundation
import UIKit
import Photos

// MARK: - Camera Device Info
struct CameraDeviceInfo: Identifiable, Equatable {
    let id: String
    let device: AVCaptureDevice
    var displayName: String
    var icon: String
    static func == (lhs: CameraDeviceInfo, rhs: CameraDeviceInfo) -> Bool { lhs.id == rhs.id }
}

enum CaptureMode: String, CaseIterable { case photo = "PHOTO"; case video = "VIDEO"; case raw = "RAW" }
enum ExposureMode: String, CaseIterable { case auto = "AUTO"; case manual = "MANUAL"; case av = "Av"; case tv = "Tv"; case p = "P" }

// MARK: - CameraManager
// NOT @MainActor on the class — we manage threading explicitly
final class CameraManager: NSObject, ObservableObject {

    // Session (accessed only on sessionQueue)
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.manualcam.session", qos: .userInitiated)
    private let photoOutput  = AVCapturePhotoOutput()

    // videoInput accessed only on sessionQueue
    private var _videoInput: AVCaptureDeviceInput?

    // Published — updated on MainActor
    @Published var availableCameras: [CameraDeviceInfo] = []
    @Published var activeCamera: CameraDeviceInfo?
    @Published var currentISO: Float = 400
    @Published var currentShutterSpeed: CMTime = CMTimeMake(value: 1, timescale: 125)
    @Published var currentLensPosition: Float = 1.0
    @Published var currentZoom: CGFloat = 1.0
    @Published var currentWBTemp: Float = 5500
    @Published var isoRange: ClosedRange<Float> = 50...6400
    @Published var shutterRange: ClosedRange<Double> = (1.0/8000)...30.0
    @Published var evRange: ClosedRange<Float> = -3...3
    @Published var zoomRange: ClosedRange<CGFloat> = 1...10
    @Published var supportsRAW: Bool = false
    @Published var supportsAppleLog: Bool = false
    @Published var supportsLiDAR: Bool = false
    @Published var supportsTorch: Bool = false
    @Published var isTorchOn: Bool = false
    @Published var lastPhoto: UIImage?
    // FIX: dedicated array — updated in photo delegate, never races with fireShutter()
    @Published var capturedPhotos: [UIImage] = []
    @Published var focusPoint: CGPoint? = nil
    @Published var permissionGranted: Bool = false
    @Published var errorMessage: String? = nil

    // Polling timer replaces KVO (avoids all concurrency issues)
    private var pollTimer: Timer?

    // MARK: - Setup
    func setup() {
        Task { await checkPermissions() }
    }

    private func checkPermissions() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await MainActor.run { self.permissionGranted = true }
            configureSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run { self.permissionGranted = granted }
            if granted { configureSession() }
        default:
            await MainActor.run { self.permissionGranted = false }
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            // Discover cameras
            let types: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera,
                .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
                .builtInTrueDepthCamera, .builtInLiDARDepthCamera,
            ]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)

            let cameras: [CameraDeviceInfo] = discovery.devices.map { device in
                var name = "Camera", icon = "camera"
                switch device.deviceType {
                case .builtInUltraWideCamera:  name = "Ultra Wide"; icon = "0.5x"
                case .builtInWideAngleCamera:  name = device.position == .front ? "Front" : "Wide"; icon = device.position == .front ? "person" : "1x"
                case .builtInTelephotoCamera:  name = "Telephoto"; icon = "3x"
                case .builtInDualCamera:       name = "Dual"; icon = "2x"
                case .builtInDualWideCamera:   name = "Dual Wide"; icon = "2x"
                case .builtInTripleCamera:     name = "Triple"; icon = "3x"
                case .builtInLiDARDepthCamera: name = "LiDAR"; icon = "lidar"
                case .builtInTrueDepthCamera:  name = "TrueDepth"; icon = "face"
                default: break
                }
                return CameraDeviceInfo(id: device.uniqueID, device: device, displayName: name, icon: icon)
            }

            DispatchQueue.main.async { self.availableCameras = cameras }

            // Pick best back camera
            let preferred = discovery.devices.first {
                $0.deviceType == .builtInWideAngleCamera && $0.position == .back
            } ?? discovery.devices.first

            if let device = preferred {
                self.attachDevice(device)
                DispatchQueue.main.async {
                    self.activeCamera = cameras.first { $0.id == device.uniqueID }
                }
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                if #available(iOS 16.0, *) {
                    self.photoOutput.maxPhotoDimensions = .init(width: 4032, height: 3024)
                }
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            // Start polling for live readout
            DispatchQueue.main.async { self.startPolling() }
        }
    }

    // MARK: - Attach device (called on sessionQueue)
    private func attachDevice(_ device: AVCaptureDevice) {
        // Remove old input
        if let old = _videoInput { session.removeInput(old) }
        _videoInput = nil

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                _videoInput = input
            }
        } catch {
            DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            return
        }

        // Update capabilities on main thread
        DispatchQueue.main.async { self.updateCapabilities(for: device) }
    }

    // MARK: - Switch Camera (callable from any thread)
    func switchCamera(to info: CameraDeviceInfo) {
        DispatchQueue.main.async { self.activeCamera = info }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachDevice(info.device)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Capabilities (called on main thread)
    private func updateCapabilities(for device: AVCaptureDevice) {
        isoRange     = device.activeFormat.minISO...device.activeFormat.maxISO
        let minSS    = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxSS    = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        shutterRange = minSS...maxSS
        evRange      = device.minExposureTargetBias...device.maxExposureTargetBias
        zoomRange    = 1.0...Swift.min(device.activeFormat.videoMaxZoomFactor, 10.0)
        supportsTorch = device.hasTorch
        supportsLiDAR = device.deviceType == .builtInLiDARDepthCamera
        supportsRAW   = photoOutput.availableRawPhotoPixelFormatTypes.count > 0
        if #available(iOS 17.0, *) {
            supportsAppleLog = device.formats.contains { $0.supportedColorSpaces.contains(.appleLog) }
        }
    }

    // MARK: - Polling (replaces KVO, runs on main thread)
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollDeviceValues()
        }
    }

    private func pollDeviceValues() {
        // Read device values on sessionQueue, publish on main
        sessionQueue.async { [weak self] in
            guard let self, let device = self._videoInput?.device else { return }
            let iso      = device.iso
            let shutter  = device.exposureDuration
            let lens     = device.lensPosition
            let zoom     = device.videoZoomFactor
            let gains    = device.deviceWhiteBalanceGains
            let temp     = device.temperatureAndTintValues(for: gains).temperature
            DispatchQueue.main.async {
                self.currentISO           = iso
                self.currentShutterSpeed  = shutter
                self.currentLensPosition  = lens
                self.currentZoom          = zoom
                self.currentWBTemp        = temp
            }
        }
    }

    // MARK: - Manual Controls
    func setISO(_ iso: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            let clamped = iso.clamped(to: device.activeFormat.minISO...device.activeFormat.maxISO)
            try? device.lockForConfiguration()
            device.setExposureModeCustom(duration: device.exposureDuration, iso: clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setShutterSpeed(_ seconds: Double) {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            let minSS = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
            let maxSS = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
            let clamped  = seconds.clamped(to: minSS...maxSS)
            let duration = CMTimeMakeWithSeconds(clamped, preferredTimescale: 1_000_000)
            try? device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: device.iso, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setEV(_ ev: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            let clamped = ev.clamped(to: device.minExposureTargetBias...device.maxExposureTargetBias)
            try? device.lockForConfiguration()
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setWhiteBalanceTemp(_ kelvin: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            try? device.lockForConfiguration()
            var gains = device.deviceWhiteBalanceGains(for:
                AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0))
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain   = Swift.min(Swift.max(gains.redGain,   1.0), maxGain)
            gains.greenGain = Swift.min(Swift.max(gains.greenGain, 1.0), maxGain)
            gains.blueGain  = Swift.min(Swift.max(gains.blueGain,  1.0), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setAutoWhiteBalance() {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            try? device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        }
    }

    func setFocus(lensPosition: Float) {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            let clamped = Swift.min(Swift.max(lensPosition, 0), 1)
            try? device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    func setAutoFocus() {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }
    }

    func tapToFocus(at point: CGPoint, in viewSize: CGSize) {
        let devicePoint = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height)
        DispatchQueue.main.async { self.focusPoint = point }

        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.focusPoint = nil
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            let maxZoom = Swift.min(device.activeFormat.videoMaxZoomFactor, 10.0)
            let clamped = Swift.min(Swift.max(factor, 1.0), maxZoom)
            try? device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self?.currentZoom = clamped }
        }
    }

    func setTorch(_ on: Bool) {
        DispatchQueue.main.async { self.isTorchOn = on }
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device, device.hasTorch else { return }
            try? device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func setAutoExposure() {
        sessionQueue.async { [weak self] in
            guard let device = self?._videoInput?.device else { return }
            try? device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Capture
    func capturePhoto(rawEnabled: Bool = false) {
        let settings: AVCapturePhotoSettings
        if rawEnabled, let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = .init(width: 4032, height: 3024)
        }
        settings.flashMode = isTorchOn ? .on : .off
        if photoOutput.isDepthDataDeliverySupported {
            settings.isDepthDataDeliveryEnabled = true
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - Photo Delegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { DispatchQueue.main.async { self.errorMessage = error.localizedDescription }; return }

        // Save to Photos library
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                if let data = photo.fileDataRepresentation() {
                    req.addResource(with: photo.isRawPhoto ? .alternatePhoto : .photo, data: data, options: nil)
                }
            }
        }

        // FIX 2+3: Build image with correct portrait orientation
        // photo.fileDataRepresentation() preserves EXIF orientation
        // We explicitly fix it so UIImage displays correctly in the gallery
        guard let data = photo.fileDataRepresentation() else { return }
        guard let rawImage = UIImage(data: data) else { return }

        // Normalise orientation to portrait up
        let img: UIImage
        if rawImage.imageOrientation == .up {
            img = rawImage
        } else {
            // Re-draw into a context to bake the orientation in
            UIGraphicsBeginImageContextWithOptions(rawImage.size, false, rawImage.scale)
            rawImage.draw(in: CGRect(origin: .zero, size: rawImage.size))
            img = UIGraphicsGetImageFromCurrentImageContext() ?? rawImage
            UIGraphicsEndImageContext()
        }

        DispatchQueue.main.async {
            self.lastPhoto = img
            // Prepend to array so gallery always shows newest first
            self.capturedPhotos.insert(img, at: 0)
        }
    }
}

// MARK: - Clamping
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
