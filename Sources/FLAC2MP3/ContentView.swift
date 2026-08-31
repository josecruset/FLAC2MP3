import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = FLAC2MP3ViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FLAC2MP3")
                .font(.largeTitle.weight(.semibold))

            GroupBox("Conversion settings") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField("Music folder", text: $viewModel.folderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isRunning)
                        Button("Choose…", action: viewModel.browse)
                            .disabled(viewModel.isRunning)
                    }
                    Toggle("Search subdirectories recursively", isOn: $viewModel.recursive)
                        .disabled(viewModel.isRunning)
                    Picker("MP3 quality", selection: $viewModel.quality) {
                        ForEach(MP3Quality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(viewModel.isRunning)
                    Text("V0 VBR is the recommended default from the conversion guide. CUE sheets are split into tagged tracks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Progress") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(viewModel.status)
                            .font(.headline)
                        Spacer()
                        if viewModel.totalJobs > 0 {
                            Text("\(viewModel.currentIndex)/\(viewModel.totalJobs)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if viewModel.isRunning {
                        ProgressView(value: overallProgress)
                        if let currentProgress = viewModel.currentProgress {
                            ProgressView(value: currentProgress)
                                .controlSize(.small)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    if !viewModel.currentFile.isEmpty {
                        Text(viewModel.currentFile)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Label("Converted \(viewModel.convertedCount)", systemImage: "checkmark.circle")
                        Label("Skipped \(viewModel.skippedCount)", systemImage: "forward.end")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            HStack {
                Button(viewModel.isRunning ? "Running…" : "Start conversion", action: viewModel.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart)
                Button("Cancel", action: viewModel.cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!viewModel.isRunning)
                Spacer()
                Button("Clear log", action: viewModel.clearLog)
                    .disabled(viewModel.isRunning || viewModel.logLines.isEmpty)
            }

            GroupBox("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 180)
                    .onChange(of: viewModel.logLines.count) { count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .alert("Conversion stopped", isPresented: errorBinding) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    private var overallProgress: Double {
        guard viewModel.totalJobs > 0 else { return 0 }
        return min(1, max(0, Double(viewModel.currentIndex - (viewModel.currentProgress == 1 ? 0 : 1)) / Double(viewModel.totalJobs)))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}
