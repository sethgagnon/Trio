import AVFoundation
import SwiftUI
import VisionKit

/// SwiftUI wrapper for VisionKit barcode scanner
struct BarcodeScannerView: View {
    @Binding var isPresented: Bool
    var onBarcodeScanned: (String) -> Void

    @State private var showPermissionAlert = false
    @State private var isSupported = false

    var body: some View {
        NavigationStack {
            Group {
                if isSupported {
                    BarcodeScannerRepresentable(
                        onBarcodeScanned: { barcode in
                            onBarcodeScanned(barcode)
                            isPresented = false
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Scanner Not Available",
                        systemImage: "barcode.viewfinder",
                        description: Text("This device doesn't support barcode scanning")
                    )
                }
            }
            .navigationTitle("Scan Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .alert("Camera Access Required", isPresented: $showPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
            } message: {
                Text("Please allow camera access in Settings to scan barcodes.")
            }
        }
        .onAppear {
            checkSupportAndPermissions()
        }
    }

    private func checkSupportAndPermissions() {
        // Check if DataScanner is supported
        isSupported = DataScannerViewController.isSupported && DataScannerViewController.isAvailable

        // Check camera permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        showPermissionAlert = true
                    }
                }
            }
        case .denied,
             .restricted:
            showPermissionAlert = true
        @unknown default:
            break
        }
    }
}

/// UIViewControllerRepresentable for DataScannerViewController
struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    var onBarcodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [
                    .ean8,
                    .ean13,
                    .upce,
                    .code128,
                    .code39,
                    .code93,
                    .itf14,
                    .qr
                ])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context _: Context) {
        // Start scanning if not already
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBarcodeScanned: onBarcodeScanned)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onBarcodeScanned: (String) -> Void
        private var hasScanned = false

        init(onBarcodeScanned: @escaping (String) -> Void) {
            self.onBarcodeScanned = onBarcodeScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            processItem(item, scanner: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems _: [RecognizedItem]
        ) {
            // Auto-capture first recognized barcode
            guard !hasScanned, let item = addedItems.first else { return }
            processItem(item, scanner: dataScanner)
        }

        private func processItem(_ item: RecognizedItem, scanner: DataScannerViewController) {
            guard !hasScanned else { return }

            switch item {
            case let .barcode(barcode):
                if let value = barcode.payloadStringValue {
                    hasScanned = true
                    scanner.stopScanning()

                    // Haptic feedback
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)

                    onBarcodeScanned(value)
                }
            default:
                break
            }
        }

        func dataScanner(
            _: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            print("Scanner unavailable: \(error.localizedDescription)")
        }
    }
}

#Preview {
    BarcodeScannerView(isPresented: .constant(true)) { barcode in
        print("Scanned: \(barcode)")
    }
}
