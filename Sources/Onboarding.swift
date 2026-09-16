//  Onboarding.swift — what a new machine sees the first time the app runs.

import SwiftUI

final class OnboardingModel: ObservableObject {
    @Published var accessibility = Actions.hasAccessibility
    @Published var screenRecording = CGPreflightScreenCaptureAccess()
    @Published var remoteStatus = "Looking for the remote…"
    @Published var lastButton: String?

    private var timer: Timer?
    private let controller: Controller

    init(controller: Controller) {
        self.controller = controller
        controller.onButtonSeen = { [weak self] cid in
            DispatchQueue.main.async { self?.lastButton = Spotlight.controlName(cid) }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        accessibility = Actions.hasAccessibility
        screenRecording = CGPreflightScreenCaptureAccess()
        remoteStatus = controller.statusText
    }

    var ready: Bool { accessibility && controller.device.connected }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Presenter").font(.largeTitle.bold())
                Text("Full Logitech Spotlight support for this Mac.")
                    .foregroundStyle(.secondary)
            }

            step(1, "Plug in the receiver, or pair the remote over Bluetooth",
                 detail: model.remoteStatus,
                 done: model.remoteStatus.lowercased().contains("ready"))

            step(2, "Allow Accessibility",
                 detail: "Lets the remote send arrow keys to Keynote, PowerPoint and Google Slides. Until this is on, the app leaves the remote alone and it works as a plain clicker.",
                 done: model.accessibility) {
                Button("Open Settings") {
                    Actions.requestAccessibility()
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }

            step(3, "Allow Screen Recording — optional",
                 detail: "Only the magnifier needs this, because it has to read the pixels it enlarges. Everything else works without it.",
                 done: model.screenRecording) {
                Button("Open Settings") {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }

            Divider()

            HStack {
                Image(systemName: model.lastButton == nil ? "hand.point.up.left" : "checkmark.circle.fill")
                    .foregroundStyle(model.lastButton == nil ? Color.secondary : Color.green)
                Text(model.lastButton.map { "Got it — \($0)" } ?? "Press any button on the remote to test it.")
                    .foregroundStyle(model.lastButton == nil ? .secondary : .primary)
                Spacer()
                Button(model.ready ? "Done" : "Skip for now", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private func step(_ n: Int, _ title: String, detail: String, done: Bool,
                      @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(width: 24, height: 24)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                else { Text("\(n)").font(.caption.bold()).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !done { action() }
        }
    }
}
