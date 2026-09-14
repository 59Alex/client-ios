import AVKit
import SwiftUI

/// Выбор устройства звука в звонке (`QuickVoiceSettings.tsx`): системный список динамика, наушников и Bluetooth.
struct AudioRoutePicker: UIViewRepresentable {
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = tint
        view.activeTintColor = tint
        view.accessibilityLabel = "Устройство звука"
        view.accessibilityIdentifier = "call.audioRoute"
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}
