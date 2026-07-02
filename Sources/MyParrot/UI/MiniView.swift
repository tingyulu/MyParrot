import SwiftUI
import MyParrotCore

/// Floating mini mode — always-on-top pill with the mascot, timer, dual meters,
/// and transport. (Window-level "float above all" is set via NSWindow in v1.x.)
struct MiniView: View {
    let controller: RecordingController
    @Binding var miniMode: Bool

    var body: some View {
        HStack(spacing: 9) {
            ParrotMascot(size: 22, isRecording: controller.state == .recording)
            Circle().fill(MP.recRed).frame(width: 8, height: 8)
                .opacity(controller.state == .recording ? 1 : 0.25)
            Text(MP.clock(controller.elapsed))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
            VStack(spacing: 4) {
                miniMeter(controller.otherLevel, MP.coral,
                          live: controller.state == .recording, ok: controller.sysHasSignal)
                miniMeter(controller.youLevel, MP.blue,
                          live: controller.state == .recording, ok: controller.micHasSignal)
            }.frame(width: 52)

            switch controller.state {
            case .recording:
                iconBtn("pause") { controller.pause() }
                iconBtn("stop") { controller.stop() }
            case .paused:
                iconBtn("play") { controller.resume() }
                iconBtn("stop") { controller.stop() }
            default:
                iconBtn("record.circle") { controller.startRecording() }
            }
            iconBtn("plus") { controller.newRecording() }
            iconBtn("arrow.up.left.and.arrow.down.right") { miniMode = false }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(minWidth: 300)
    }

    private func miniMeter(_ v: Float, _ c: Color, live: Bool = false, ok: Bool = false) -> some View {
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3).fill(c)
                        .frame(width: max(1, geo.size.width * CGFloat(min(1, v))))
                }
            }.frame(height: 5)
            if live {
                Circle().fill(ok ? Color.green : Color.orange).frame(width: 5, height: 5)
            }
        }
    }

    private func iconBtn(_ name: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: name).font(.system(size: 15)) }
            .buttonStyle(.plain)
    }
}
