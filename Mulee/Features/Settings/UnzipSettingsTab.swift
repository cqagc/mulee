import SwiftUI

/// 设置·解压。
struct UnzipSettingsTab: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: $model.autoExtract) {
                    Text("下载完成后自动解压")
                    Text("支持 zip / rar / 7z 及分卷；分卷会等全部下完再解压")
                }
            }
            Section("密码规则 · 按顺序匹配，命中即停") {
                UnzipRulesTable()
                    .listRowInsets(EdgeInsets())
            }
            Section("自动找密码") {
                Toggle(isOn: $model.detectPagePassword) {
                    Text("从下载页面的文字里识别「解压密码：xxx」")
                    Text("需要安装浏览器扩展")
                }
                Toggle("读取压缩包注释里的密码", isOn: $model.readArchiveComment)
            }
            Section("解压后") {
                LabeledContent {
                    Picker("文件名编码", selection: $model.filenameEncoding) {
                        Text("自动检测").tag(SettingsModel.FilenameEncoding.auto)
                        Text("GBK").tag(SettingsModel.FilenameEncoding.gbk)
                        Text("Big5").tag(SettingsModel.FilenameEncoding.big5)
                        Text("Shift-JIS").tag(SettingsModel.FilenameEncoding.shiftJIS)
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("文件名编码")
                    Text("修复 GBK / Big5 / Shift-JIS 的乱码文件名")
                }
                LabeledContent {
                    Picker("解压成功后的原压缩包", selection: $model.originalAction) {
                        Text("保留").tag(SettingsModel.OriginalArchiveAction.keep)
                        Text("移到废纸篓").tag(SettingsModel.OriginalArchiveAction.trash)
                        Text("删除").tag(SettingsModel.OriginalArchiveAction.delete)
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("解压成功后的原压缩包")
                    Text("解压失败时原文件一律不动")
                }
                Toggle(isOn: $model.extractNested) {
                    Text("嵌套压缩包也解压")
                    Text("例如 rar 里套 zip")
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    UnzipSettingsTab()
        .environment(AppModel())
        .environment(SettingsModel())
}
