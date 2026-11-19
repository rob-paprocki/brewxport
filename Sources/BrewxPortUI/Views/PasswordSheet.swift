import SwiftUI
import BrewxPortRun

/// Asks for the administrator password once per run. The field's text goes into a `SecretBuffer` the moment it's
/// submitted, and the field is cleared straight away.
struct PasswordSheet: View {
    let reason: String
    let previousAttemptFailed: Bool
    /// Shown above the field (demo mode's note), when there is one.
    var note: String? = nil
    let onFinish: @MainActor (SecretBuffer?) -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Administrator password").font(.headline)
            Text(reason).fixedSize(horizontal: false, vertical: true)
            if previousAttemptFailed {
                Text("That password didn't work").foregroundStyle(.red)
            }
            if let note {
                Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            SecureField("Password", text: $text)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    text = ""
                    onFinish(nil)
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// The temporary byte array is zeroed (`memset_s`, which the compiler can't drop) once `SecretBuffer` has its
    /// own copy. The field's `String` can't be wiped: SwiftUI's `SecureField` only binds to a Swift `String`,
    /// whose storage is immutable and may be shared, so the best this can do is drop the reference straight away.
    private func submit() {
        guard !text.isEmpty else { return }
        var bytes = Array(text.utf8)
        let secret = SecretBuffer(copying: bytes)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
        text = ""
        onFinish(secret)
    }
}
