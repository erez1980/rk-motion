import BackgroundTasks
import Foundation

/// Opt-in only for a distribution profile that includes background GPU access.
/// Unsupported devices/SDKs/denied requests keep the foreground fallback.
@MainActor final class ContinuedProcessing {
    static let shared = ContinuedProcessing()
    private var registered = false
    private var running = false
    private var taskObject: AnyObject?
    private var launch: (() -> Void)?
    private var expire: (() -> Void)?
    private var identifier: String {(Bundle.main.bundleIdentifier ?? "com.rkmotion.companion") + ".mediaProcessing"}
    var hasActiveTask: Bool {taskObject != nil}
    var enabled: Bool {
        guard #available(iOS 26.0, *), Bundle.main.object(forInfoDictionaryKey: "RKBackgroundGPUEnabled") as? String == "YES" else {return false}
        return BGTaskScheduler.supportedResources.contains(.gpu)
    }
    func start(title: String, launch: @escaping () -> Void, expire: @escaping () -> Void) -> Bool {
        guard #available(iOS 26.0, *), enabled, !running else {return false}
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) {job in
                guard let task = job as? BGContinuedProcessingTask else {job.setTaskCompleted(success: false); return}
                Task { @MainActor in
                    guard self.running, let launch = self.launch else {task.setTaskCompleted(success: false); return}
                    self.taskObject = task; task.progress.totalUnitCount = 1000
                    task.expirationHandler = {
                        Task { @MainActor in
                            self.expire?()
                            self.complete(success: false)
                        }
                    }
                    launch()
                }
            }
        }
        guard registered else {return false}
        self.launch = launch; self.expire = expire; running = true
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: NSLocalizedString(title, comment: "Continued processing task title"), subtitle: NSLocalizedString("העיבוד מתבצע באייפון", comment: "Continued processing task subtitle"))
        request.strategy = .fail; request.requiredResources = .gpu
        do {try BGTaskScheduler.shared.submit(request); return true}
        catch {running = false; self.launch = nil; self.expire = nil; return false}
    }
    func update(_ fraction: Double, subtitle: String) {
        guard #available(iOS 26.0, *), let task = taskObject as? BGContinuedProcessingTask else {return}
        task.progress.completedUnitCount = Int64(max(0, min(1, fraction)) * 1000)
        // The system shows this outside the app, past every view that would
        // localize it, so the catalog lookup has to happen here.
        task.updateTitle(task.title, subtitle: NSLocalizedString(subtitle, comment: "Continued processing progress"))
    }
    func complete(success: Bool) {
        if #available(iOS 26.0, *), let task = taskObject as? BGContinuedProcessingTask {task.setTaskCompleted(success: success)}
        taskObject = nil; running = false; launch = nil; expire = nil
    }
}
