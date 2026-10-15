import Foundation

/// App 包内打包的 aria2 运行时资源（约定见 docs/BUILDING.md）。
///
/// Homebrew 编译的 OpenSSL 把模块目录和证书目录写死在 /opt/homebrew 下；
/// 从 App 包里启动 aria2c 时，必须显式告诉它模块和根证书在哪，否则在没装 Homebrew 的机器上起不来、HTTPS 也会失败。
struct Aria2BundleResources: Equatable {
    /// OpenSSL 模块目录，通过环境变量 OPENSSL_MODULES 传给 aria2c。
    var openSSLModules: URL?
    /// 根证书包，通过 --ca-certificate 传给 aria2c。
    var caCertificate: URL?

    /// 只有当 aria2c 位于 `<App>.app/Contents/Helpers/aria2c` 时才解析包内资源；其他位置（例如 Homebrew）返回空。
    static func resolve(binary: URL, fileManager: FileManager = .default) -> Aria2BundleResources {
        let helpers = binary.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers" else { return Aria2BundleResources() }
        let contents = helpers.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return Aria2BundleResources() }

        let modules = contents.appending(path: "Frameworks/aria2/ossl-modules", directoryHint: .isDirectory)
        let certificate = contents.appending(path: "Resources/aria2/cert.pem")
        return Aria2BundleResources(
            openSSLModules: fileManager.fileExists(atPath: modules.path) ? modules : nil,
            caCertificate: fileManager.fileExists(atPath: certificate.path) ? certificate : nil
        )
    }

    /// 追加到 aria2c 命令行的参数（只含路径，不含任何密钥）。
    var additionalArguments: [String] {
        caCertificate.map { ["--ca-certificate=\($0.path)"] } ?? []
    }

    /// 写入子进程环境的变量。
    func apply(to environment: inout [String: String]) {
        if let openSSLModules {
            environment["OPENSSL_MODULES"] = openSSLModules.path
        }
    }
}
