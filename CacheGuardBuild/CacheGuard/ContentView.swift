import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = CleanerViewModel()
    @StateObject private var airlift = AirLiftCoordinator.shared
    @State private var showingFolderPicker = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    accessCard
                    scanCard
                    if !model.buckets.isEmpty { resultsCard }
                    if let result = model.lastResult { completedCard(result) }
                    if let message = model.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    warningCard
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("清存")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("v0.7")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.selectFolder(url) }
            case .failure(let error):
                model.message = error.localizedDescription
            }
        }
        .confirmationDialog(
            "确认清理所选文件？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除候选文件", role: .destructive) {
                model.cleanSelected()
            }
        } message: {
            Text("删除不可撤销，外部文件夹可能含离线内容。不会清理未授权的 App 或系统数据。建议先备份。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("缓存扫描与安全清理")
                    .font(.headline)
            }
            Text("当前设备：\(model.operatingSystem)")
                .font(.subheadline)
            Text("仅对可访问文件进行扫描。扫描数值是候选文件的估算大小，不代表系统实际释放空间。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("权限诊断", systemImage: "lock.shield")
                .font(.headline)
            accessRow("本应用缓存", subtitle: "标准沙盒权限", isReady: true)
            accessRow("手动选择的文件夹", subtitle: "使用系统文件选择器授权", isReady: true)
            accessRow(
                "AirLift 配对记录",
                subtitle: "\(airlift.hasRecord ? "已有配对文件" : "尚未配对")；需进一步验证设备服务",
                isReady: airlift.hasRecord
            )
            accessRow("微信、抖音等其他 App", subtitle: "容器查询可试验，批量缓存清理暂不可用", isReady: false)
            accessRow("系统数据", subtitle: "未验证安全删除能力，不提供批量清理", isReady: false)
            NavigationLink {
                AirLiftSetupView()
            } label: {
                HStack {
                    Label("AirLift 配对与诊断", systemImage: "network.badge.shield.half.filled")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
        }
        .cardSurface()
    }

    private func accessRow(_ title: String, subtitle: String, isReady: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "lock.circle.fill")
                .foregroundStyle(isReady ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(isReady ? "可用" : "未解锁")
                .font(.caption.weight(.medium))
                .foregroundStyle(isReady ? Color.green : Color.orange)
        }
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("开始扫描", systemImage: "magnifyingglass")
                .font(.headline)
            Button {
                showingFolderPicker = true
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("选择额外文件夹")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            if let folder = model.chosenFolder {
                Text("已选择：\(folder.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Button {
                model.scan()
            } label: {
                HStack {
                    Spacer()
                    if model.isBusy { ProgressView().tint(.white) }
                    Text(model.isBusy ? "正在处理…" : "扫描可访问缓存")
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
        .cardSurface()
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("扫描结果", systemImage: "list.bullet.rectangle")
                .font(.headline)
            ForEach(model.buckets) { bucket in
                Button {
                    model.toggle(bucket.source)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: model.selected.contains(bucket.source)
                            ? "checkmark.square.fill" : "square")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bucket.source.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(bucket.count) 项 · \(ByteText.format(bucket.bytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if bucket.truncated {
                                Text("扫描不完整或权限受限，不能批量清理")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                Divider()
            }
            Text("已选估算：\(ByteText.format(model.selectedBytes))")
                .font(.subheadline.weight(.medium))
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("确认清理所选项目")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!model.canClean)
        }
        .cardSurface()
    }

    private func completedCard(_ result: DeleteSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("清理结果", systemImage: "checkmark.shield")
                .font(.headline)
            Text("删除 \(result.deletedCount) 项，候选文件估算 \(ByteText.format(result.estimatedBytes))")
            Text("跳过 \(result.skippedCount) 项，失败 \(result.failedCount) 项。实际腾出的容量可能不同。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("安全说明", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
            Text("本版本已接入 AirLift 配对与只读容器路径查询，但尚未开放越权删除。普通缓存清理仍仅作用于本 App 或手动授权的文件夹，并排除数据库、偏好设置等敏感类型。无法保证所有离线内容都可重建。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
}
