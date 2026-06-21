import SwiftUI

struct MachineCreationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if store.machineCreationError == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.red).font(.system(size: 18))
                }
                Text(store.machineCreationTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(p.text)
                Spacer()
            }

            ScrollView {
                Text(store.machineCreationLog)
                    .font(.mono(11))
                    .foregroundStyle(p.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(p.monoBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            .frame(height: 160)

            if let error = store.machineCreationError {
                Text(error).font(.system(size: 12.5)).foregroundStyle(p.red).lineLimit(nil)
                Button {
                    store.activeSheet = nil
                    store.machineCreationError = nil
                } label: {
                    Text("Close").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 280)
        .background(p.bgWindow)
    }
}
