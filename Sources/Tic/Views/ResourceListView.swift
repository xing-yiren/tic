import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The note's attached resources, shown under the checklist: files, folders, repos (with a Finder
/// reveal), and web links (which open in the browser). Drag a file/folder in, paste or add a URL, and
/// remove or relocate individual links. Removing a link never deletes the original.
struct ResourceListView: View {
    @Bindable var controller: NoteController
    let theme: NoteTheme

    @State private var dropTargeted = false
    @State private var showLinkSheet = false
    @State private var linkText = ""
    @State private var linkError: String?
    @State private var unreachable: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.resources) { resource in
                row(resource)
            }
            addBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.accent.opacity(0.10))
                    .allowsHitTesting(false)
            }
        }
        .task(id: controller.resources.map(\.id)) {
            await refreshReachability()
        }
    }

    private func row(_ resource: ResourceSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: resource.kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(theme.accent)
                .frame(width: 16)

            Text(resource.label)
                .font(.callout)
                .foregroundStyle(theme.task)
                .lineLimit(1)
                .truncationMode(.middle)

            if unreachable.contains(resource.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("The original can't be found — relocate it")
            }

            Spacer(minLength: 4)

            if unreachable.contains(resource.id), resource.isLocal {
                Button("Relocate") { relocate(resource) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.accent)
            }

            Button { controller.openResource(resource) } label: {
                Image(systemName: resource.kind == .web ? "arrow.up.right.square" : "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
            }
            .buttonStyle(.plain)
            .help(resource.kind == .web ? "Open in browser" : "Open")

            if resource.isLocal {
                Button { controller.revealResource(resource) } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            } else {
                Button { ResourceAccessService.copyLink(resource.url) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy link")
            }

            Button { controller.removeResource(resource) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove link (keeps the original)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.openResource(resource) }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Button {
                pickFiles()
            } label: {
                Label("Add file or folder", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
            }
            .buttonStyle(.plain)

            Button {
                linkText = ""
                linkError = nil
                showLinkSheet = true
            } label: {
                Label("Add link", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(theme.secondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .popover(isPresented: $showLinkSheet, arrowEdge: .bottom) { linkPopover }
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add web link").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField("https://…", text: $linkText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(addLink)
            if let linkError {
                Text(linkError).font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Add", action: addLink)
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { controller.attachResource(at: url) }
    }

    private func addLink() {
        let raw = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (_, kind) = AppDatabase.validatedResourceURL(raw), kind == .web else {
            linkError = "Enter a valid http(s) link."
            return
        }
        controller.attachWebLink(raw)
        showLinkSheet = false
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in controller.attachResource(at: url) }
                }
            }
        }
        return handled
    }

    private func relocate(_ resource: ResourceSummary) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink"
        panel.message = "Locate “\(resource.label)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.relocateResource(resource, to: url)
    }

    private func refreshReachability() async {
        var next: Set<UUID> = []
        for resource in controller.resources where resource.isLocal {
            if await !controller.resourceIsReachable(resource) { next.insert(resource.id) }
        }
        unreachable = next
    }
}
