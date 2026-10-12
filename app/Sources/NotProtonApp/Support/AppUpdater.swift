import Foundation
import Sparkle

@MainActor
final class AppUpdater {

    let isEnabled: Bool
    private let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        isEnabled = (bundle.object(forInfoDictionaryKey: "NPDisableUpdates") as? Bool) != true
        guard isEnabled else {
            controller = nil
            return
        }
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func check() {
        guard isEnabled else { return }
        #if !DEBUG
        controller?.checkForUpdates(nil)
        #endif
    }
}
