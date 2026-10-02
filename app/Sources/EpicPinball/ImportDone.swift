import SwiftUI

/// The end of the import: what was imported, and the offer to make HD art packs of every table
/// in the background (HDPackGeneration, scale 4x by default). Unticking the box skips it and goes
/// straight to the picker; packs can be made later in Settings > Library.
struct ImportDonePanel: View {
    @Bindable var model: AppModel
    var tables: Int
    var warnings: [String]
    @State private var makePacks = true
    @State private var scale = HDPackGeneration.defaultScale

    var body: some View {
        VStack(spacing: 14) {
            Text("Imported \(tables) tables").font(.headline).foregroundStyle(Theme.accent)
            ForEach(warnings.prefix(6), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $makePacks) {
                    Text("Make HD art packs now").font(.system(size: 14, weight: .semibold))
                }
                .toggleStyle(.checkbox)
                HStack(spacing: 10) {
                    Text("Scale").foregroundStyle(Theme.dim)
                    Picker("Scale", selection: $scale) {
                        ForEach(HDPackGeneration.appScales, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .disabled(!makePacks)
                Text("Sharper table art, made on this Mac from your own files with the built-in xBRZ filter, in the "
                     + "background (well under a minute for all tables). Display > Use HD art pack is switched on when they are "
                     + "ready. You can also make them later in Settings > Library.")
                    .font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 460, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.panelBorder))
            Button(makePacks ? "Make HD packs and choose a table" : "Choose a table") {
                model.finishImport(makeHDPacks: makePacks, scale: scale)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .environment(\.colorScheme, .dark)   // the launcher's dark theme, whatever the system appearance
    }
}

/// HD pack generation running in the background (import offer or Settings > Library): a slim bar
/// at the bottom of the picker with the progress and Cancel; the result stays until dismissed.
struct HDPackProgressBar: View {
    @Bindable var model: AppModel
    @State private var dismissed: String?

    var body: some View {
        switch model.hdPackState {
        case let .running(f, m):
            bar {
                Text("HD art packs").font(.callout.weight(.semibold))
                ProgressView(value: min(max(f, 0), 1)).progressViewStyle(.linear).frame(width: 220).tint(Theme.accent)
                Text("\(Int((min(max(f, 0), 1) * 100).rounded())) %  \(m)").font(.caption).foregroundStyle(Theme.dim).lineLimit(1).fixedSize()
                Spacer()
                Button("Cancel") { model.cancelHDPacks() }
            }
        case let .finished(m) where dismissed != m:
            bar {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent)
                Text(m).font(.caption).foregroundStyle(Theme.dim).lineLimit(2)
                Spacer()
                Button("OK") { dismissed = m }
            }
        case let .failed(m) where dismissed != m:
            bar {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("HD packs: \(m)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                Button("OK") { dismissed = m }
            }
        default:
            EmptyView()
        }
    }

    private func bar<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 12) { c() }
            .buttonStyle(.bordered)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.35))
            .environment(\.colorScheme, .dark)
    }
}
