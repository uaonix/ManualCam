import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.applyPortrait()
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.applyPortrait()
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        applyPortrait()
    }

    func applyPortrait() {
        // Fix the preview connection to portrait
        if let conn = previewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        // Also fix the transform — counteract any CALayer rotation
        // that UIKit may have applied due to device orientation
        previewLayer.setAffineTransform(.identity)
    }
}
