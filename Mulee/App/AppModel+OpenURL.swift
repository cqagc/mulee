import Foundation
import MuleeCore

extension AppModel {
    /// 在确认草稿后，将来源与临时密码绑定到本次新建的任务。
    func addTasks(
        from links: [ParsedLink], autoExtract: Bool, directory: URL? = nil,
        filePriorities: [ParsedLink: [Int]] = [:],
        contexts: [ParsedLink: NewTaskContext]
    ) {
        if let coordinator {
            Task {
                for link in links.reversed() {
                    let previousIDs = Set(tasks.map(\.id))
                    await coordinator.add(
                        links: [link], autoExtract: autoExtract, directory: directory, filePriorities: filePriorities
                    )
                    for index in tasks.indices where !previousIDs.contains(tasks[index].id) && tasks[index].sourceLink == link.original {
                        tasks[index].sourcePageURL = contexts[link]?.sourcePageURL
                        if let password = contexts[link]?.password { pagePasswords[tasks[index].id] = password }
                    }
                }
            }
            return
        }
        let newTasks = links.map { link in
            var task = DownloadTask(link: link, autoExtract: autoExtract)
            task.sourcePageURL = contexts[link]?.sourcePageURL
            if let password = contexts[link]?.password { pagePasswords[task.id] = password }
            return task
        }
        tasks.insert(contentsOf: newTasks, at: 0)
        selectedTaskID = newTasks.first?.id ?? selectedTaskID
    }
}
