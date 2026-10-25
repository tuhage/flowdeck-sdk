#if os(iOS)
import SwiftUI

/// Present inside a sheet/fullScreenCover; close() dismisses that SwiftUI presentation.
@MainActor
public struct FlowdeckView: View {
    private let flowdeck: Flowdeck
    private let placementID: String
    @Environment(\.dismiss) private var dismiss
    @State private var controller: FlowdeckViewController?
    @State private var error: String?
    @State private var attempt = 0

    public init(flowdeck: Flowdeck, placementID: String) {
        self.flowdeck = flowdeck
        self.placementID = placementID
    }

    public var body: some View {
        Group {
            if let controller {
                Presentation(controller: controller, close: { dismiss() })
            } else if let error {
                VStack(spacing: 16) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Retry") { attempt += 1 }
                    Button("Close") { dismiss() }
                }.padding()
            } else {
                ProgressView()
            }
        }
        .task(id: "\(placementID)-\(attempt)") {
            error = nil
            controller = nil
            do {
                let loaded = try await flowdeck.makeViewController(placementID: placementID)
                try Task.checkCancellation()
                controller = loaded
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private struct Presentation: UIViewControllerRepresentable {
        let controller: FlowdeckViewController
        let close: () -> Void
        func makeUIViewController(context: Context) -> FlowdeckViewController {
            controller.onDismiss = close
            return controller
        }
        static func dismantleUIViewController(_ controller: FlowdeckViewController, coordinator: ()) {
            controller.reportClosed()
        }
        func updateUIViewController(_ uiViewController: FlowdeckViewController, context: Context) {
            uiViewController.onDismiss = close
        }
    }
}
#endif
