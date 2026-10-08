import SwiftUI

struct PairingView: View {
    @ObservedObject var model: IOSConnectionModel
    var onReady: (() -> Void)? = nil
    var scanOnAppear = false
    @State private var showingScanner = false
    @State private var scanError: String?
    @State private var showingCelebration = false
    // Once ever, not on every re-pair (a lost connection reconnecting, a second Mac being added)
    // - the "show someone" moment only makes sense the very first time this account gets a PC.
    @AppStorage("wiqo.hasSeenPairingCelebration") private var hasSeenPairingCelebration = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .wiqoRiseIn()
                Text("PC'ye bağlan")
                    .font(.title2.weight(.semibold))
                    .wiqoRiseIn(delay: 0.08)
                Text("Wiqo PC'de gösterilen QR kodu tara.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .wiqoRiseIn(delay: 0.16)
                Button {
                    showingScanner = true
                } label: {
                    Label("QR tara", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.wiqoPill(.accent))
                .wiqoRiseIn(delay: 0.24)
                if model.isPairing {
                    WiqoStatusLine(text: String(localized: "PC'yi bağlıyorum…"))
                        .font(.subheadline)
                }
                if let error = scanError ?? model.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(WiqoTheme.red)
                        .multilineTextAlignment(.center)
                        .transition(.wiqoBlur)
                }
                Spacer()
            }
            .padding(28)
            .wiqoAnimation(WiqoMotion.slide(), value: model.isPairing)
            .wiqoAnimation(WiqoMotion.slide(), value: scanError ?? model.lastError)
            .navigationTitle("Wiqo")
            .sheet(isPresented: $showingScanner) {
                QRScannerView { value in
                    showingScanner = false
                    do {
                        switch try RovaQRCodec.decodePairingCode(value) {
                        case .local(let payload): model.pair(using: payload)
                        case .relay(let payload): model.pair(using: payload)
                        }
                        scanError = nil
                    } catch {
                        scanError = String(localized: "Geçersiz Wiqo QR kodu.")
                    }
                } onCancel: {
                    showingScanner = false
                }
                .ignoresSafeArea()
            }
        }
        // The scanner sheet already closes itself the instant a code is captured; this is what
        // closes the *outer* "PC'ye bağlan" screen once that scan actually finishes pairing -
        // without it, a successful pairing left the user staring at a screen that had already
        // done its job, with no obvious next step but to swipe it away manually.
        .onChange(of: model.state) { _, state in
            guard model.isPaired, state == .connected else { return }
            if let onReady {
                onReady()
                return
            }
            if hasSeenPairingCelebration {
                dismiss()
            } else {
                hasSeenPairingCelebration = true
                showingCelebration = true
            }
        }
        .onAppear {
            if scanOnAppear && !model.isPaired { showingScanner = true }
        }
        .sheet(isPresented: $showingCelebration, onDismiss: { dismiss() }) {
            PairingCelebrationView()
        }
    }
}

/// A one-time, one-shot "wow" moment right after the very first pairing - the whole product
/// spreads best when someone sees this happen in person, so the app should say so out loud
/// instead of leaving that realization to chance.
struct PairingCelebrationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            WiqoCheckmark(color: WiqoTheme.green, lineWidth: 5)
                .frame(width: 54, height: 54)
                .padding(20)
                .background(WiqoTheme.tint(WiqoTheme.green), in: Circle())
            Text("PC'n bağlandı!")
                .font(.title2.weight(.bold))
                .wiqoRiseIn(delay: 0.2)
            Text("Şimdi yanındaki birine telefonundan söyle:")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .wiqoRiseIn(delay: 0.3)
            Text("\"Sesi kıs\"")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(WiqoTheme.inset, in: Capsule())
                .wiqoRiseIn(delay: 0.4)
            Text("Wiqo telefonundan gerçekten PC'ni kontrol ediyor - bunu görmek en iyi anlatımdır.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .wiqoRiseIn(delay: 0.5)
            Spacer()
            WiqoActionButton(title: String(localized: "Harika!")) { dismiss() }
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 32)
        .presentationDetents([.medium])
        .onAppear { WiqoHaptics.success() }
    }
}
