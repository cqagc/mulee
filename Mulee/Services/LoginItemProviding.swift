import ServiceManagement

protocol LoginItemProviding {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSettings()
}
