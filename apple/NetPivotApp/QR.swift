import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import VisionKit

struct InvitationQR: View {
    let url: URL

    var body: some View {
        if let image {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 168, height: 168)
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 12))
                .accessibilityLabel("邀请二维码")
        }
    }

    private var image: UIImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(url.absoluteString.utf8)
        guard let output = generator.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct QRScanner: View {
    let receive: (String) -> Void
    @State private var allowed: Bool?

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported || allowed == false {
                ContentUnavailableView("无法使用相机", systemImage: "camera.badge.ellipsis",
                    description: Text("请在系统设置中检查相机权限，或返回输入邀请码。"))
            } else if allowed == true && DataScannerViewController.isAvailable {
                ScannerController(receive: receive)
            } else if allowed == true {
                ContentUnavailableView("相机暂不可用", systemImage: "camera.badge.ellipsis",
                    description: Text("试着关闭占用相机的应用，或返回输入邀请码。"))
            } else {
                ProgressView("正在检查相机权限")
            }
        }
        .task {
            guard DataScannerViewController.isSupported else { return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
        }
    }
}

private struct ScannerController: UIViewControllerRepresentable {
    let receive: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { context.coordinator.showError(in: scanner) }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(receive: receive) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let receive: (String) -> Void
        private var delivered = false
        init(receive: @escaping (String) -> Void) { self.receive = receive }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered, case let .barcode(item)? = addedItems.first, let value = item.payloadStringValue else { return }
            delivered = true
            dataScanner.stopScanning()
            receive(value)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            showError(in: dataScanner)
        }

        func showError(in scanner: UIViewController) {
            let message = UILabel()
            message.text = "相机无法启动。请检查权限，或返回输入邀请码。"
            message.textAlignment = .center
            message.numberOfLines = 0
            message.backgroundColor = .systemBackground
            message.frame = scanner.view.bounds
            message.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scanner.view.addSubview(message)
        }
    }
}
