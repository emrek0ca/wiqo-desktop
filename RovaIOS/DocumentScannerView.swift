import SwiftUI
import VisionKit

/// The system document camera: finds page edges, straightens and cleans each page. Wiqo reads the
/// pages on device (FileContentExtractor) and sends only the recognized text.
struct DocumentScannerView: UIViewControllerRepresentable {
    let onFinish: ([UIImage], Bool) -> Void
    let onCancel: () -> Void
    let onError: () -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onError: onError)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([UIImage], Bool) -> Void
        private let onCancel: () -> Void
        private let onError: () -> Void

        init(onFinish: @escaping ([UIImage], Bool) -> Void, onCancel: @escaping () -> Void, onError: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pageLimit = min(scan.pageCount, FileContentExtractor.maxScanPages)
            var pages: [UIImage] = []
            pages.reserveCapacity(pageLimit)
            for index in 0..<pageLimit {
                autoreleasepool {
                    pages.append(downsample(scan.imageOfPage(at: index)))
                }
            }
            onFinish(pages, scan.pageCount > pageLimit)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onError()
        }

        private func downsample(_ image: UIImage) -> UIImage {
            let sourcePixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            let factor = min(1, CGFloat(FileContentExtractor.maxImagePixelDimension) / max(sourcePixels.width, sourcePixels.height))
            guard factor < 1 else { return image }
            let outputSize = CGSize(width: sourcePixels.width * factor, height: sourcePixels.height * factor)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: outputSize))
            }
        }
    }
}
