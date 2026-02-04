import SwiftUI
import VisionKit

struct BarcodeScannerView: View {
    @Binding var isPresented: Bool
    let onBarcodeScanned: (String) -> Void

    @State private var scannerAvailable = DataScannerViewController.isSupported &&
        DataScannerViewController.isAvailable

    var body: some View {
        NavigationStack {
            Group {
                if scannerAvailable {
                    DataScannerRepresentable(onBarcodeScanned: { barcode in
                        onBarcodeScanned(barcode)
                        isPresented = false
                    })
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Scanner Not Available",
                        systemImage: "barcode.viewfinder",
                        description: Text("Barcode scanning requires a device with a camera.")
                    )
                }
            }
            .navigationTitle("Scan Food Barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onBarcodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean8, .ean13, .upce, .code128])
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

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onBarcodeScanned: onBarcodeScanned)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBarcodeScanned: (String) -> Void
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

            if case let .barcode(barcode) = item {
                hasScanned = true
                scanner.stopScanning()

                // Provide haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                onBarcodeScanned(barcode.payloadStringValue ?? "")
            }
        }
    }
}
