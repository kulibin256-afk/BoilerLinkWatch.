import SwiftUI
import Combine
import BackgroundTasks
import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@main @MainActor
struct LinkWatchApp: App {
    @StateObject private var monitor = LinkMonitor.shared
    @Environment(\.scenePhase) private var scenePhase
    init() { UNUserNotificationCenter.current().delegate = NotificationDelegate.shared }
    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor)
                .task { await monitor.activate() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await monitor.activate() } }
                    else if phase == .background { monitor.deactivate() }
                }
        }
        .backgroundTask(.appRefresh(LinkMonitor.taskID)) {
            await LinkMonitor.shared.backgroundRefresh()
        }
    }
}

@MainActor
final class LinkMonitor: ObservableObject {
    static let shared = LinkMonitor()
    static let taskID = "ua.boilermonitor.linkwatch.refresh"
    static let alarmID = "link-unconfirmed"
    @Published var enabled = UserDefaults.standard.bool(forKey: "enabled")
    @Published var address = UserDefaults.standard.string(forKey: "address") ?? ""
    @Published var lastSuccess = UserDefaults.standard.object(forKey: "lastSuccess") as? Date
    @Published var lastAttempt: Date?
    @Published var message = "Контроль ще не виконувався"
    @Published var scheduling = ""
    private var enabledAt = UserDefaults.standard.object(forKey: "enabledAt") as? Date
    private var loop: Task<Void, Never>?
    private var inFlight = false
    private var foregroundAlarm = false

    func activate() async {
        guard enabled else { return }
        loop?.cancel()
        await refresh()
        guard enabled else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                guard !Task.isCancelled, let self, self.enabled else { return }
                await self.refresh()
            }
        }
    }
    func deactivate() { loop?.cancel(); loop = nil; scheduleBackground() }
    func setEnabled(_ value: Bool) async {
        if !value {
            enabled = false; UserDefaults.standard.set(false, forKey: "enabled")
            loop?.cancel(); loop = nil
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [Self.alarmID, "link-failed-check", "link-test"])
            center.removeDeliveredNotifications(withIdentifiers: [Self.alarmID, "link-failed-check", "link-test"])
            message = "Контроль вимкнений"; scheduling = ""; return
        }
        guard let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil else {
            message = "Вкажіть коректну HTTPS-адресу перевірки"; return
        }
        do {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                message = "Дозвольте сповіщення в параметрах iPhone"; return
            }
            enabled = true; enabledAt = Date(); foregroundAlarm = false; lastSuccess = nil
            UserDefaults.standard.set(true, forKey: "enabled")
            UserDefaults.standard.set(address, forKey: "address")
            UserDefaults.standard.set(enabledAt, forKey: "enabledAt")
            UserDefaults.standard.removeObject(forKey: "lastSuccess")
            await armReminder(); await activate()
        } catch { message = "Не вдалося ввімкнути сповіщення: \(error.localizedDescription)" }
    }
    func backgroundRefresh() async { guard enabled else { return }; await refresh(); scheduleBackground() }
    func scheduleBackground() {
        guard enabled else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        do { try BGTaskScheduler.shared.submit(request); scheduling = "Наступну перевірку запитано через 15 хв; час визначає iOS" }
        catch { scheduling = "iOS не прийняла фонову перевірку: \(error.localizedDescription)" }
    }
    func refresh() async {
        guard enabled, !inFlight, let url = URL(string: address), url.scheme == "https" else { return }
        inFlight = true; defer { inFlight = false }
        lastAttempt = Date()
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "BOILER_MONITOR_OK" else {
                throw URLError(.badServerResponse)
            }
            guard enabled else { return }
            lastSuccess = Date(); foregroundAlarm = false
            UserDefaults.standard.set(lastSuccess, forKey: "lastSuccess")
            message = "Комп’ютер відповідає"
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.alarmID])
            await armReminder()
        } catch {
            guard enabled else { return }
            message = "Немає відповіді: \(error.localizedDescription)"
            // An actual failed foreground check is distinct from a delayed background task.
            if Date().timeIntervalSince(lastSuccess ?? enabledAt ?? Date()) >= 60, !foregroundAlarm {
                foregroundAlarm = true
                await notify(title: "Зв’язок не підтверджено", body: "Понад хвилину немає успішної відповіді. Перевірте інтернет iPhone та комп’ютер.", after: 1, identifier: "link-failed-check")
            }
        }
        scheduleBackground()
    }
    private func armReminder() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.alarmID])
        await notify(title: "Перевірте зв’язок із котельнями", body: "20 хвилин немає підтвердження від комп’ютера. Можливо, відсутній інтернет або iOS відклала перевірку. Відкрийте програму.", after: 20 * 60, identifier: Self.alarmID)
    }
    private func notify(title: String, body: String, after seconds: Double, identifier: String) async {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))) }
        catch { message = "Помилка місцевого сповіщення: \(error.localizedDescription)" }
    }
    func testSound() async { await notify(title: "Контроль зв’язку", body: "Тест місцевого сповіщення без сервера", after: 5, identifier: "link-test") }
}

struct ContentView: View {
    @ObservedObject var monitor: LinkMonitor
    var body: some View {
        NavigationStack {
            Form {
                Section("Зв’язок із комп’ютером") {
                    TextField("HTTPS-адреса", text: $monitor.address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(monitor.enabled)
                    Toggle("Контроль увімкнений", isOn: Binding(get: { monitor.enabled }, set: { value in Task { await monitor.setEnabled(value) } }))
                    Text(monitor.message)
                    if let date = monitor.lastSuccess { LabeledContent("Остання відповідь", value: date.formatted(date: .numeric, time: .standard)) }
                    if let date = monitor.lastAttempt { LabeledContent("Остання спроба", value: date.formatted(date: .omitted, time: .standard)) }
                    Button("Перевірити зараз") { Task { await monitor.refresh() } }.disabled(!monitor.enabled)
                    Button("Тест сигналу через 5 секунд") { Task { await monitor.testSound() } }.disabled(!monitor.enabled)
                }
                Section("Експериментальний режим") {
                    Text("У відкритій програмі — запит щохвилини. У фоні — запит перевірки через 15 хвилин; iOS може відкласти або пропустити його.")
                    Text("Після кожної відповіді планується місцеве нагадування через 20 хвилин. Воно працює без інтернету, але може спрацювати навіть при справному комп’ютері, якщо iOS не запустила перевірку.")
                    Text("Звук залежить від дозволів, беззвучного режиму та зосередження. Це не гарантована аварійна сигналізація.")
                    Text(monitor.scheduling).font(.caption)
                }
                if let endpoint = URL(string: monitor.address), let host = endpoint.host,
                   let home = URL(string: "https://" + host) {
                    Link("Відкрити монітор котелень", destination: home)
                }
            }.navigationTitle("Контроль зв’язку")
        }
    }
}
