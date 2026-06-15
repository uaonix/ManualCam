import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session      = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.forcePortrait()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Re-apply on every SwiftUI update (e.g. camera switch)
        uiView.forcePortrait()
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        forcePortrait()
    }

    func forcePortrait() {
        guard let conn = previewLayer.connection else { return }

        // iOS 17+ API — use rotation angle (0° = portrait)
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(0) {
                conn.videoRotationAngle = 0
                return
            }
        }

        // iOS 16 fallback — use videoOrientation
        if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }

        // Reset any CALayer transform iOS may have applied
        previewLayer.setAffineTransform(.identity)
    }
}
