import SwiftUI

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, [(String, String)])] = [
        ("Everywhere", [("⌘O", "Choose a folder"), ("⌘1 ⌘2 ⌘3", "Confirm, Look, Deliver"), ("⌘4", "Album"), ("⌘D", "Adjust the selected photo"), ("⌘Z", "Undo the last mark"), ("⌃⌘S", "Show or hide the sidebar")]),
        ("Album", [("Space", "Open or close the large view"), ("Esc / G", "Back to the grid"), ("← →", "Previous or next photo"), ("↑ ↓", "Previous or next frame in a burst"), ("P / X / U", "Pick, reject, clear"), ("1–5 / 0", "Stars / clear stars"), ("6 7 8 9", "Red, yellow, green, blue label"), ("S", "Survey the burst side by side"), ("F", "Fit or 100%"), ("E", "Zoom to eyes"), ("\\", "Show original")]),
        ("Confirm", [("Return", "Keep the suggestion"), ("← →", "Move between frames"), ("P", "Keep the selected frame"), ("X", "Drop a single photo"), ("Esc", "Skip this moment"), ("E", "Check eyes")])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard shortcuts")
                .font(.title2.weight(.semibold))
            ForEach(sections, id: \.0) { title, items in
                VStack(alignment: .leading, spacing: 6) {
                    StudioSectionHeader(title: title)
                    ForEach(items, id: \.1) { key, action in
                        HStack {
                            Text(key)
                                .font(.callout.monospaced())
                                .frame(width: 110, alignment: .leading)
                            Text(action)
                                .foregroundStyle(StudioChrome.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(StudioChrome.panel)
    }
}
