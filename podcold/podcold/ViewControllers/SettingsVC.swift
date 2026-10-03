import UIKit

class SettingsVC: UIViewController, UITableViewDelegate, UITableViewDataSource, UIAlertViewDelegate {

    private lazy var tableView = UITableView(frame: .zero, style: .grouped)
    private var pendingImport: BackupManager.BackupContents?

    private let bg = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = bg

        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.delegate   = self
        tableView.dataSource = self
        tableView.backgroundColor = UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)
        tableView.separatorColor  = UIColor(white: 1, alpha: 0.1)
        view.addSubview(tableView)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { return 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return section == 2 ? 2 : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:  return "Downloads"
        case 1:  return "New Episodes"
        default: return "Backup & Restore"
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return "When on, the downloaded file is deleted once an episode finishes playing or you tap Done."
        case 1:
            return "How many of a podcast's most recent unplayed episodes can be offered. Once you tap Done on all of them, that podcast stays quiet until it publishes something new."
        default:
            return "To migrate to a new device: export, share via email, then copy the .json file to the new device via iTunes/Finder File Sharing and tap Import."
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1)
        cell.textLabel?.backgroundColor        = .clear
        cell.detailTextLabel?.backgroundColor  = .clear
        cell.textLabel?.textColor              = .white
        cell.detailTextLabel?.textColor        = UIColor(white: 1, alpha: 0.4)
        cell.selectionStyle                    = .default

        if indexPath.section == 0 {
            cell.textLabel?.text = "Delete after playing"
            cell.selectionStyle  = .none
            let sw = UISwitch()
            sw.isOn = Episode.autoDeleteFinished
            sw.addTarget(self, action: #selector(autoDeleteChanged(_:)), for: .valueChanged)
            cell.accessoryView = sw
            return cell
        }

        if indexPath.section == 1 {
            cell.textLabel?.text = "Max new episodes"
            cell.detailTextLabel?.text = "\(UpNextManager.maxNewEpisodes)"
            cell.selectionStyle = .none
            let stepper = UIStepper()
            stepper.minimumValue = Double(UpNextManager.maxNewEpisodesRange.lowerBound)
            stepper.maximumValue = Double(UpNextManager.maxNewEpisodesRange.upperBound)
            stepper.stepValue    = 1
            stepper.value        = Double(UpNextManager.maxNewEpisodes)
            stepper.addTarget(self, action: #selector(maxNewEpisodesChanged(_:)), for: .valueChanged)
            cell.accessoryView = stepper
            return cell
        }

        if indexPath.row == 0 {
            cell.textLabel?.text = "Export backup"
            let count = Podcast.loadSubscriptions().count
            cell.detailTextLabel?.text = "\(count) subscription\(count == 1 ? "" : "s")"
        } else {
            cell.textLabel?.text = "Import backup"
            let count = BackupManager.listBackupFiles().count
            cell.detailTextLabel?.text = count == 0 ? "No files" : "\(count) file\(count == 1 ? "" : "s")"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { return 50 }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2 else { return }
        if indexPath.row == 0 { handleExport() }
        else                  { handleImport() }
    }

    // MARK: - Downloads

    @objc private func autoDeleteChanged(_ sender: UISwitch) {
        Episode.autoDeleteFinished = sender.isOn
    }

    // MARK: - New Episodes

    @objc private func maxNewEpisodesChanged(_ sender: UIStepper) {
        UpNextManager.maxNewEpisodes = Int(sender.value)
        // Each cache entry is one already-chosen episode, re-checked only every 45 min,
        // so the new window would go unfelt until then. Clearing forces a re-parse.
        LatestEpisodeCache.clear()
        // Repainting just the label, not reloadSections: rebuilding the cell would swap
        // out the stepper the finger is still on and kill its press-and-hold repeat.
        let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 1))
        cell?.detailTextLabel?.text = "\(Int(sender.value))"
    }

    // MARK: - Export

    private func handleExport() {
        guard let result = BackupManager.export() else {
            showInfo(title: "Export failed", message: "Could not write backup file.")
            return
        }
        tableView.reloadData()
        let fileURL = URL(fileURLWithPath: result.filePath)
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        present(activity, animated: true, completion: nil)
    }

    // MARK: - Import

    private func handleImport() {
        let files = BackupManager.listBackupFiles()
        guard !files.isEmpty else {
            showInfo(title: "No backup files found",
                     message: "Copy a podcold-backup-*.json file to this device via iTunes or Finder File Sharing, then tap Import.")
            return
        }
        guard let backup = BackupManager.parse(filePath: files[0]) else {
            showInfo(title: "Import failed", message: "Could not read \((files[0] as NSString).lastPathComponent).")
            return
        }
        pendingImport = backup
        let msg = "\(backup.subscriptionCount) subscription\(backup.subscriptionCount == 1 ? "" : "s") · \(backup.downloadCount) download\(backup.downloadCount == 1 ? "" : "s") · \(backup.positionCount) position\(backup.positionCount == 1 ? "" : "s")\n\(backup.playedCount) played · \(backup.queueCount) queued"

        // Safe multi-button UIAlertView: use addButton, NOT the vararg init.
        // The ObjC nil-terminated vararg does not get a nil terminator from Swift — crashes on iOS 6.
        let alert = UIAlertView()
        alert.title   = "Import \"\(backup.exportDate)\"?"
        alert.message = msg
        alert.delegate = self
        alert.addButton(withTitle: "Cancel")   // index 0
        alert.addButton(withTitle: "Replace")  // index 1
        alert.addButton(withTitle: "Merge")    // index 2
        alert.cancelButtonIndex = 0
        alert.tag = 1
        alert.show()
    }

    // MARK: - UIAlertViewDelegate

    func alertView(_ alertView: UIAlertView, clickedButtonAt buttonIndex: Int) {
        guard alertView.tag == 1, let backup = pendingImport else { return }
        pendingImport = nil
        switch buttonIndex {
        case 1: BackupManager.applyImport(backup, mode: .replace)
        case 2: BackupManager.applyImport(backup, mode: .merge)
        default: return
        }
        tableView.reloadData()
        title = "Settings - Imported"
        // Reset title after a short delay
        let t = Timer(timeInterval: 2.0, target: self, selector: #selector(resetTitle), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
    }

    @objc private func resetTitle() { title = "Settings" }

    // MARK: - Helpers

    private func showInfo(title: String, message: String) {
        let alert = UIAlertView()
        alert.title   = title
        alert.message = message
        alert.addButton(withTitle: "OK")
        alert.cancelButtonIndex = 0
        alert.show()
    }
}
