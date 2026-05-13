import Foundation
import Observation
import AppKit

/// Auto-updater that polls the project's GitHub releases for a newer build,
/// downloads the signed+notarized zip asset, and either replaces the
/// running bundle in-place (one-click Restart & Install) or falls back to
/// "Reveal in Finder" when the current bundle lives outside /Applications/
/// (e.g. a dev build under DerivedData).
@Observable
@MainActor
final class UpdaterService {

    // MARK: - Public state

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(progress: Double, release: Release)
        case readyToInstall(appURL: URL, release: Release)
        case error(String)
    }

    struct Release: Hashable, Sendable {
        let tagName: String       // "v0.1.2" or "v0.2.0-beta"
        let version: String       // "0.1.2" or "0.2.0-beta"
        let title: String
        let notes: String
        let htmlURL: URL
        let publishedAt: Date?
        let isPrerelease: Bool
        let assetName: String
        let assetURL: URL
        let assetSize: Int64
    }

    var phase: Phase = .idle
    private(set) var lastChecked: Date?

    let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

    // MARK: - Config

    private static let repo = "xVanTuring/ZedisUI"

    /// Reads UserDefaults each time so the Preferences toggle takes effect
    /// without a restart.
    private var includePrereleases: Bool {
        UserDefaults.standard.bool(forKey: "updater.includePrereleases")
    }

    // MARK: - Check

    /// Hits the GitHub API and updates `phase` to `.upToDate` or
    /// `.available(_)`. `silent` only affects callers that observe phase —
    /// when true, the launcher will only auto-open the update window if a
    /// new release exists.
    @discardableResult
    func check(silent: Bool = false) async -> Phase {
        if case .checking = phase { return phase }
        if case .downloading = phase { return phase }
        if case .readyToInstall = phase { return phase }

        phase = .checking
        defer { lastChecked = Date() }

        do {
            let release = try await fetchLatestRelease()
            if Self.compareVersions(release.version, currentVersion) > 0 {
                phase = .available(release)
            } else if silent {
                phase = .idle
            } else {
                phase = .upToDate
            }
        } catch UpdaterError.noReleases {
            phase = silent ? .idle : .upToDate
        } catch {
            phase = .error(error.localizedDescription)
        }
        return phase
    }

    func reset() {
        // Stay out of the in-flight states.
        switch phase {
        case .checking, .downloading: return
        default: phase = .idle
        }
    }

    // MARK: - Download + extract

    func downloadAndInstall(_ release: Release) async {
        phase = .downloading(progress: 0, release: release)
        do {
            let zipURL = try await downloadAsset(release)
            let appURL = try extractApp(from: zipURL)
            phase = .readyToInstall(appURL: appURL, release: release)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    /// Opens Finder with the unpacked .app selected so the user can drag
    /// it into /Applications.
    func revealInFinder() {
        guard case .readyToInstall(let url, _) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// True when the current bundle lives somewhere the sandbox + temp
    /// exception lets us replace it (i.e. inside `/Applications/`). Used
    /// to gate the "Restart & Install" button — for dev builds running
    /// out of DerivedData we degrade to the manual reveal flow.
    var canInstallInPlace: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// One-click install: hand a small shell to the system that waits for
    /// us to exit, swaps the bundle on disk, and relaunches. Returns
    /// false when we can't proceed; on success the app terminates and
    /// never returns.
    @discardableResult
    func installAndRestart() -> Bool {
        guard case .readyToInstall(let newAppURL, _) = phase else { return false }
        let currentBundleURL = Bundle.main.bundleURL
        guard canInstallInPlace else {
            phase = .error("Auto-install only works when ZedisUI is in /Applications. Use Reveal in Finder to install manually.")
            return false
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let src = shellEscape(newAppURL.path)
        let dst = shellEscape(currentBundleURL.path)
        let backup = shellEscape(currentBundleURL.path + ".old-update")

        // The subshell is detached with `&` so it survives our exit.
        // Sequence: wait for parent → move old aside → ditto new in place
        // → on failure roll back → on success delete the backup and open
        // the new bundle.
        let script = """
        (
          while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
          sleep 0.5
          rm -rf \(backup) 2>/dev/null
          if ! /bin/mv \(dst) \(backup); then exit 1; fi
          if ! /usr/bin/ditto \(src) \(dst); then
            /bin/mv \(backup) \(dst)
            exit 2
          fi
          /bin/rm -rf \(backup)
          /usr/bin/open \(dst)
        ) &
        """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        do {
            try proc.run()
        } catch {
            phase = .error("Failed to start installer: \(error.localizedDescription)")
            return false
        }

        // Quit now — the subshell is waiting for our PID to disappear.
        NSApplication.shared.terminate(nil)
        return true
    }

    /// POSIX single-quote escape so paths with spaces or quotes survive
    /// substitution into the install script.
    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens the release page on github.com.
    func openReleasePage() {
        let release: Release? = {
            switch phase {
            case .available(let r): return r
            case .downloading(_, let r): return r
            case .readyToInstall(_, let r): return r
            default: return nil
            }
        }()
        guard let release else { return }
        NSWorkspace.shared.open(release.htmlURL)
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> Release {
        // /releases/latest excludes pre-releases. If the user opted into
        // pre-releases, fall back to /releases and pick the first that
        // matches, since that endpoint returns them in publish order.
        let endpoint = includePrereleases
            ? "https://api.github.com/repos/\(Self.repo)/releases?per_page=10"
            : "https://api.github.com/repos/\(Self.repo)/releases/latest"

        var req = URLRequest(url: URL(string: endpoint)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ZedisUI/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.message("GitHub returned an unexpected response.")
        }
        if http.statusCode == 404 {
            // /releases/latest returns 404 when the repo has no published
            // releases yet — treat as "nothing to update".
            throw UpdaterError.noReleases
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdaterError.message("GitHub API error: HTTP \(http.statusCode).")
        }

        let payload: GHReleasePayload
        if includePrereleases {
            let list = try JSONDecoder().decode([GHReleasePayload].self, from: data)
            // Pick the newest by published_at among non-draft releases.
            guard let pick = list
                .filter({ $0.draft != true })
                .sorted(by: { ($0.published_at ?? "") > ($1.published_at ?? "") })
                .first
            else {
                throw UpdaterError.message("No releases available.")
            }
            payload = pick
        } else {
            payload = try JSONDecoder().decode(GHReleasePayload.self, from: data)
        }

        guard let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdaterError.message("Release \(payload.tag_name) has no .zip asset.")
        }
        guard let url = URL(string: asset.browser_download_url) else {
            throw UpdaterError.message("Bad asset URL on \(payload.tag_name).")
        }

        let tag = payload.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let iso = ISO8601DateFormatter()

        return Release(
            tagName: tag,
            version: version,
            title: payload.name ?? tag,
            notes: payload.body ?? "",
            htmlURL: URL(string: payload.html_url) ?? url,
            publishedAt: payload.published_at.flatMap { iso.date(from: $0) },
            isPrerelease: payload.prerelease,
            assetName: asset.name,
            assetURL: url,
            assetSize: asset.size
        )
    }

    private struct GHReleasePayload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let published_at: String?
        let prerelease: Bool
        let draft: Bool?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
        }
    }

    // MARK: - Download

    private func downloadAsset(_ release: Release) async throws -> URL {
        // Use a streaming bytes(for:) so we can update progress as bytes
        // arrive. URLSession.download(...) gives us no progress hook from
        // an async context without delegate plumbing.
        var req = URLRequest(url: release.assetURL)
        req.setValue("ZedisUI/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdaterError.message("Asset download failed.")
        }

        let expected = max(release.assetSize, http.expectedContentLength)
        let dest = try cachedZipURL(for: release)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var received: Int64 = 0
        var lastReportedPct = -1

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if expected > 0 {
                    let pct = Int(Double(received) / Double(expected) * 100)
                    if pct != lastReportedPct {
                        lastReportedPct = pct
                        let progress = Double(received) / Double(expected)
                        // Hop back to MainActor — `for try await` is fine
                        // since the whole method is @MainActor isolated.
                        if case .downloading(_, let r) = phase {
                            phase = .downloading(progress: min(progress, 0.999), release: r)
                        }
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        return dest
    }

    private func cachedZipURL(for release: Release) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(release.assetName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    // MARK: - Extract

    private func extractApp(from zipURL: URL) throws -> URL {
        let workDir = zipURL.deletingLastPathComponent()
            .appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // `-x -k <zip> <dest>` unpacks the PKZip archive; matches the
        // `ditto -c -k --keepParent` used in release.sh.
        proc.arguments = ["-x", "-k", zipURL.path, workDir.path]
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? nil
            let errOut = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw UpdaterError.message("Failed to unpack update: \(errOut.isEmpty ? "ditto exited \(proc.terminationStatus)" : errOut)")
        }

        let contents = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.message("No .app found inside the downloaded archive.")
        }
        return appURL
    }

    // MARK: - Version compare

    /// Returns positive if `a > b`, negative if `a < b`, 0 otherwise.
    /// Treats "0.1.2-beta" as older than "0.1.2".
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let (an, ap) = split(a)
        let (bn, bp) = split(b)
        let len = max(an.count, bn.count)
        for i in 0..<len {
            let av = i < an.count ? an[i] : 0
            let bv = i < bn.count ? bn[i] : 0
            if av != bv { return av - bv }
        }
        switch (ap.isEmpty, bp.isEmpty) {
        case (true, true):   return 0
        case (true, false):  return  1   // a is release, b is prerelease ⇒ a wins
        case (false, true):  return -1
        case (false, false): return ap.compare(bp).rawValue
        }
    }

    private static func split(_ raw: String) -> (numbers: [Int], pre: String) {
        var v = raw
        if v.hasPrefix("v") { v.removeFirst() }
        let parts = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let nums = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        let pre = parts.count > 1 ? String(parts[1]) : ""
        return (nums, pre)
    }
}

enum UpdaterError: LocalizedError {
    case message(String)
    case noReleases
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .noReleases: return nil
        }
    }
}
