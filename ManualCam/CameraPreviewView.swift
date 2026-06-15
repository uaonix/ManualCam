import SwiftUI
import AVFoundation

// MARK: - Camera Preview
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        // FIX 1: Force portrait orientation on the preview connection
        // Without this the layer defaults to landscape on some devices
        if let connection = view.previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // Re-apply portrait orientation whenever the view updates
        // (e.g. after switching cameras)
        if let connection = uiView.previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        // Re-apply orientation on layout too (handles rotation lock edge cases)
        if let connection = previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}
