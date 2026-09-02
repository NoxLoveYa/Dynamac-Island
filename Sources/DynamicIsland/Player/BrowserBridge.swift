import Foundation
import AppKit

/// Pont pour les navigateurs et autres apps web qui ne sont pas détectées via MediaRemote GetInfo
/// (qui échoue pour les apps ad-hoc). Utilise JXA (JavaScript for Automation) via `osascript`.
final class BrowserBridge {
    private func log(_ msg: String) { }
    static let shared = BrowserBridge()

    struct WebTrack {
        var title: String
        var url: String
        var isPlaying: Bool
        var bundleID: String
        var displayName: String
    }

    // Liste des navigateurs supportés
    private let browsers: [(bundleID: String, appName: String)] = [
        ("company.thebrowser.Browser", "Arc"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave Browser"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    private func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func youtubeThumbnail(from url: String) -> String? {
        // Extrait l'ID YouTube de l'URL et retourne la miniature maxres
        guard let range = url.range(of: "v=") else {
            // Gère youtu.be/ID
            if let range2 = url.range(of: "youtu.be/") {
                let start = range2.upperBound
                let end = url[start...].firstIndex(where: { $0 == "&" || $0 == "?" || $0 == "/" }) ?? url.endIndex
                let id = String(url[start..<end])
                if !id.isEmpty { return "https://img.youtube.com/vi/\(id)/maxresdefault.jpg" }
            }
            return nil
        }
        let start = range.upperBound
        let end = url[start...].firstIndex(where: { $0 == "&" || $0 == "?" || $0 == "#" }) ?? url.endIndex
        let id = String(url[start..<end])
        if id.isEmpty { return nil }
        return "https://img.youtube.com/vi/\(id)/maxresdefault.jpg"
    }

    private func artworkFrom(url: String, title: String) -> String {
        if let thumb = youtubeThumbnail(from: url) { return thumb }
        // Pour les autres sites, on essaiera de récupérer og:image via JS (déjà dans le JXA)
        return ""
    }

    // Exécute un script JXA via osascript et retourne stdout (via fichier temp)
    private func runJXA(_ script: String, timeout: TimeInterval = 1.5) -> String? {
        log("runJXA start script length \(script.count)")
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "jxa_\(UUID().uuidString).js"
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try script.write(to: fileURL, atomically: true, encoding: .utf8)
            log("wrote temp file \(fileURL.path) exists=\(FileManager.default.fileExists(atPath: fileURL.path))")
        } catch {
            log("failed to write temp file \(error)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", fileURL.path]
        log("process arguments \(process.arguments ?? [])")
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        do {
            try process.run()
            log("process run success")
        } catch {
            log("process run failed \(error)")
            return nil
        }
        // Attente bloquante avec timeout (fonctionne sur background queue)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            log("process timeout terminate")
            process.terminate()
            // Donne un peu de temps pour terminer
            usleep(100_000)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        if let errStr = String(data: errData, encoding: .utf8), !errStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("stderr: \(errStr)")
        }
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { log("output empty"); return nil }
        log("runJXA output success length \(output.count)")
        return output
    }

    // Pour Arc/Chrome : utilise JXA avec execute javascript pour avoir le vrai titre et l'état playing
    private func snapshotForChromium(appName: String, bundleID: String) -> Snapshot? {
        log("checking \(appName) isRunning=\(isRunning(bundleID: bundleID))")
        guard isRunning(bundleID: bundleID) else { log("\(appName) not running"); return nil }

        // Script JXA optimisé : gère activeTab null et cherche dans toutes les fenêtres
        let script = """
        var app = Application("\(appName)");
        if (app.windows.length === 0) { "no windows"; } else {
          var result = "";
          try {
            var tab = null;
            // Trouve le premier onglet actif non null, sinon le premier onglet
            for (var wi2=0; wi2<app.windows.length; wi2++) {
              try {
                var w2 = app.windows[wi2];
                var cand = w2.activeTab();
                if (cand !== null) { tab = cand; break; }
              } catch(e) {}
            }
            if (tab === null) { try { tab = app.windows[0].tabs[0]; } catch(e) {} }
            if (tab === null) { result = "no tab"; }
            else {
              var info = tab.execute({javascript: "(() => { var t=document.title; var u=location.href; var v=document.querySelector('video'); var p=v?(!v.paused && !v.ended && v.currentTime>0).toString():'false'; var d=v? v.duration.toString():'0'; return t+'|||'+u+'|||'+p+'|||'+d })()"});
              if (info && info.indexOf("|||") !== -1) {
                var parts = info.split("|||");
                var p = parts[2];
                if (p === "true") { result = info; }
                else {
                  for (var wi=0; wi<app.windows.length && result === ""; wi++) {
                    var w = app.windows[wi];
                    for (var ti=0; ti<w.tabs.length; ti++) {
                      try {
                        var t2 = w.tabs[ti];
                        var u2 = t2.url();
                        if (u2.indexOf("youtube.com") === -1 && u2.indexOf("youtu.be") === -1 && u2.indexOf("soundcloud.com") === -1 && u2.indexOf("netflix.com") === -1 && u2.indexOf("twitch.tv") === -1 && u2.indexOf("vimeo.com") === -1) { continue; }
                        var info2 = t2.execute({javascript: "(() => { var t=document.title; var u=location.href; var v=document.querySelector('video'); var p=v?(!v.paused && !v.ended && v.currentTime>0).toString():'false'; var d=v? v.duration.toString():'0'; return t+'|||'+u+'|||'+p+'|||'+d })()"});
                        if (info2 && info2.split("|||")[2] === "true") { result = info2; wi=app.windows.length; break; }
                      } catch(e2) {}
                    }
                  }
                  if (result === "") { result = info; }
                }
              } else { result = info; }
            }
          } catch(e) {
            try {
              var tab2 = null;
              for (var wi3=0; wi3<app.windows.length; wi3++) {
                try { var w3=app.windows[wi3]; var c=w3.activeTab(); if(c!==null){tab2=c;break;} } catch(e) {}
              }
              if (tab2===null) { try{ tab2=app.windows[0].tabs[0]; }catch(e){} }
              if (tab2!==null) { result = tab2.title() + "|||" + tab2.url() + "|||false|||0"; } else { result = "error"; }
            } catch(e2) { result = "error"; }
          }
          result;
        }
        """

        guard let output = runJXA(script, timeout: 3.5), !output.isEmpty, output != "no windows", output != "error" else { log("\(appName) no output"); return nil }
        log("runJXA output for \(appName): \(output)")

        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 2 else { return nil }
        var title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        var url = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var isPlayingStr = parts.count > 2 ? parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines) : "false"
        var durationStr = parts.count > 3 ? parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines) : "0"
        var artwork = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) : ""
        if artwork.isEmpty { artwork = artworkFrom(url: url, title: title) }
        log("parsed title=\(title) url=\(url) isPlayingStr=\(isPlayingStr) duration=\(durationStr) artwork=\(artwork)")

        // Filtre : si le titre est vide ou juste "YouTube" sans vidéo, on ignore sauf si c'est la seule option
        // On considère que c'est du média si URL contient des domaines connus ou si une vidéo existe
        let lowerURL = url.lowercased()
        let isMediaURL = lowerURL.contains("youtube.com") || lowerURL.contains("youtu.be") ||
                         lowerURL.contains("soundcloud.com") || lowerURL.contains("netflix.com") ||
                         lowerURL.contains("spotify.com") || lowerURL.contains("twitch.tv") ||
                         lowerURL.contains("vimeo.com") || lowerURL.contains("deezer.com") ||
                         lowerURL.contains("apple.com") || lowerURL.contains("bandcamp.com") ||
                         lowerURL.contains("mixcloud.com") || !title.isEmpty

        if title.isEmpty && url.isEmpty { return nil }
        // Si ce n'est pas une URL média et que la vidéo est en pause depuis longtemps, on peut quand même l'afficher
        // mais on priorisera les vrais médias. Pour l'instant on retourne seulement si c'est potentiellement média
        if !isMediaURL && isPlayingStr == "false" {
            // Vérifie si le titre ressemble à une page normale (ex: GitHub) vs une vidéo
            // Si l'URL ne contient pas de domaine média et que c'est en pause, on ignore pour ne pas polluer la pill
            // Sauf si l'app est Arc et que l'utilisateur écoute vraiment de la musique via YouTube en arrière-plan
            // On garde quand même si le titre est non vide et que l'onglet actif est YouTube
            if !lowerURL.contains("youtube.com") && !lowerURL.contains("youtu.be") {
                // On ignore les onglets non-média en pause
                // Mais on garde si c'est en lecture
                if isPlayingStr != "true" { return nil }
            }
        }

        let isPlaying = isPlayingStr.lowercased() == "true"
        let duration = Double(durationStr) ?? 0
        let trackId = "\(bundleID):\(url):\(title)"
        var snap = Snapshot()
        snap.running = true
        snap.state = isPlaying ? .playing : .paused
        snap.position = 0
        snap.track = Track(id: trackId, name: title.isEmpty ? url : title, artist: bundleID == "company.thebrowser.Browser" ? "Arc" : appName, album: url, duration: duration, artworkUrl: artwork)
        snap.bundleIdentifier = bundleID
        snap.displayName = appName
        snap.updatedAt = Date()
        log("created Chromium snap title=\(title) isPlaying=\(isPlaying) artwork=\(artwork) hasContent=\(snap.track?.hasContent ?? false)")
        return snap
    }

    private func snapshotForSafari() -> Snapshot? {
        let bundleID = "com.apple.Safari"
        log("checking Safari isRunning=\(isRunning(bundleID: bundleID))")
        guard isRunning(bundleID: bundleID) else { log("Safari not running"); return nil }
        let script = """
        var app = Application("Safari");
        if (app.documents.length === 0) { "no docs"; } else {
          var doc = app.documents[0];
          var title = doc.name();
          var url = doc.url();
          var isPlaying = "false";
          var duration = "0";
          try {
            isPlaying = app.doJavaScript("(() => { var v=document.querySelector('video'); return v ? (!v.paused).toString() : 'false' })()", {in: doc});
            duration = app.doJavaScript("(() => { var v=document.querySelector('video'); return v ? v.duration.toString() : '0' })()", {in: doc});
          } catch(e) {
            // Fallback sans JS si non autorisé
            isPlaying = "false";
          }
          title + "|||" + url + "|||" + isPlaying + "|||" + duration;
        }
        """
        guard let output = runJXA(script), !output.isEmpty, output != "no docs" else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 2 else { return nil }
        var title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        var url = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var isPlayingStr = parts.count > 2 ? parts[2].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines) : "false"
        var durationStr = parts.count > 3 ? parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines) : "0"
        var artwork = parts.count > 4 ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) : ""
        if artwork.isEmpty { artwork = artworkFrom(url: url, title: title) }
        log("Safari parsed title=\(title) url=\(url) isPlaying=\(isPlayingStr) artwork=\(artwork)")
        if title.isEmpty && url.isEmpty { log("Safari empty"); return nil }
        // Même filtre que Chromium
        let lowerURL = url.lowercased()
        let isMediaURL = lowerURL.contains("youtube.com") || lowerURL.contains("youtu.be") || lowerURL.contains("soundcloud.com") || lowerURL.contains("netflix.com") || lowerURL.contains("twitch.tv")
        if !isMediaURL && isPlayingStr == "false" {
            // Si Safari est sur Start Page ou autre, on ignore
            if title == "Start Page" || title == "Favorites" || url == "favorites://" { return nil }
            if isPlayingStr != "true" { return nil }
        }
        let isPlaying = isPlayingStr.lowercased() == "true"
        let duration = Double(durationStr) ?? 0
        var snap = Snapshot()
        snap.running = true
        snap.state = isPlaying ? .playing : .paused
        snap.track = Track(id: "\(bundleID):\(url):\(title)", name: title.isEmpty ? url : title, artist: "Safari", album: url, duration: duration, artworkUrl: artwork)
        snap.bundleIdentifier = bundleID
        snap.displayName = "Safari"
        snap.updatedAt = Date()
        log("created Safari snap title=\(title) isPlaying=\(isPlaying) artwork=\(artwork)")
        return snap
    }

    func snapshot() -> Snapshot? {
        log("snapshot start")
        // On teste chaque browser dans l'ordre de probabilité
        // Arc d'abord (utilisateur principal), puis Chrome, puis Safari
        let candidates: [Snapshot?] = [
            snapshotForChromium(appName: "Arc", bundleID: "company.thebrowser.Browser"),
            snapshotForChromium(appName: "Google Chrome", bundleID: "com.google.Chrome"),
            snapshotForChromium(appName: "Brave Browser", bundleID: "com.brave.Browser"),
            snapshotForChromium(appName: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
            snapshotForChromium(appName: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
            snapshotForSafari(),
            // Firefox est moins scriptable, on tente quand même via JXA simple
            snapshotForChromium(appName: "Firefox", bundleID: "org.mozilla.firefox"),
        ]

        log("candidates total \(candidates.count) valid before filter \(candidates.compactMap{$0}.count)")
        let valid = candidates.compactMap { $0 }.filter { $0.track?.hasContent == true }
        log("valid count \(valid.count) names \(valid.map{ $0.track?.name ?? "nil" })")
        if valid.isEmpty { log("no valid candidate"); return nil }
        // Priorité aux médias en lecture
        if let playing = valid.first(where: { $0.isPlaying }) {
            return playing
        }
        return valid.first
    }

    // MARK: - Controls (ciblent le média affiché, pas le dernier actif système)
    func togglePlayPause(bundleID: String) {
        guard let appName = browsers.first(where: { $0.bundleID == bundleID })?.appName else { return }
        if bundleID == "com.apple.Safari" {
            let script = """
            var app = Application("Safari");
            if (app.documents.length > 0) {
              var doc = app.documents[0];
              try { app.doJavaScript("(() => { var v=document.querySelector('video'); if(!v) return 'no video'; if(v.paused){ v.play(); return 'playing'; } else { v.pause(); return 'paused'; } })()", {in: doc}); "toggled"; } catch(e) { "error"; }
            } else { "no docs"; }
            """
            _ = runJXA(script, timeout: 2)
        } else {
            let script = """
            var app = Application("\(appName)");
            if (app.windows.length === 0) { "no windows"; } else {
              var done = false;
              var result = "";
              try {
                // Priorité à l'onglet actif (celui affiché dans la pill)
                var tab = app.windows[0].activeTab;
                var r = tab.execute({javascript: "(() => { var v=document.querySelector('video'); if(!v) return 'no video'; if(v.paused){ v.play(); return 'playing'; } else { v.pause(); return 'paused'; } })()"});
                if (r === "playing" || r === "paused") { result = "toggled active: " + r; done = true; }
              } catch(e) {}
              // Si l'actif n'a pas de vidéo, cherche dans tous les onglets
              for (var wi=0; wi<app.windows.length && !done; wi++) {
                var w = app.windows[wi];
                for (var ti=0; ti<w.tabs.length; ti++) {
                  try {
                    var t = w.tabs[ti];
                    var r2 = t.execute({javascript: "(() => { var v=document.querySelector('video'); if(!v) return 'no video'; if(v.paused){ v.play(); return 'playing'; } else { v.pause(); return 'paused'; } })()"});
                    if (r2 === "playing" || r2 === "paused") { result = "toggled tab " + ti + ": " + r2; done = true; break; }
                  } catch(e2) {}
                }
              }
              if (done) { result; } else { "no video"; }
            }
            """
            _ = runJXA(script, timeout: 2.5)
        }
    }

    func nextTrack(bundleID: String) {
        // Pour YouTube et sites similaires, on clique sur le bouton "suivant"
        guard let appName = browsers.first(where: { $0.bundleID == bundleID })?.appName else { return }
        if bundleID == "com.apple.Safari" {
            let script = """
            var app = Application("Safari");
            if (app.documents.length > 0) {
              var doc = app.documents[0];
              try { app.doJavaScript("(() => { var b=document.querySelector('.ytp-next-button'); if(b){ b.click(); return 'clicked'; } var n=document.querySelector('[aria-label=\\'Suivant\\']'); if(n){ n.click(); return 'clicked'; } return 'no button'; })()", {in: doc}); "done"; } catch(e) { "error"; }
            }
            """
            _ = runJXA(script, timeout: 2)
        } else {
            let script = """
            var app = Application("\(appName)");
            if (app.windows.length > 0) {
              try {
                var tab = app.windows[0].activeTab;
                tab.execute({javascript: "(() => { var b=document.querySelector('.ytp-next-button'); if(b){ b.click(); return 'clicked'; } var n=document.querySelector('[data-testid=\\"next-button\\"]'); if(n){ n.click(); return 'clicked'; } return 'no button'; })()"});
                "done";
              } catch(e) { "error"; }
            }
            """
            _ = runJXA(script, timeout: 2)
        }
    }

    func previousTrack(bundleID: String) {
        guard let appName = browsers.first(where: { $0.bundleID == bundleID })?.appName else { return }
        if bundleID == "com.apple.Safari" {
            let script = """
            var app = Application("Safari");
            if (app.documents.length > 0) {
              var doc = app.documents[0];
              try { app.doJavaScript("(() => { var v=document.querySelector('video'); if(v){ v.currentTime=0; } var b=document.querySelector('.ytp-prev-button'); if(b){ b.click(); } })()", {in: doc}); "done"; } catch(e) { "error"; }
            }
            """
            _ = runJXA(script, timeout: 2)
        } else {
            let script = """
            var app = Application("\(appName)");
            if (app.windows.length > 0) {
              try {
                var tab = app.windows[0].activeTab;
                tab.execute({javascript: "(() => { var v=document.querySelector('video'); if(v){ if(v.currentTime>3){ v.currentTime=0; } else { var b=document.querySelector('.ytp-prev-button'); if(b) b.click(); } } })()"});
                "done";
              } catch(e) { "error"; }
            }
            """
            _ = runJXA(script, timeout: 2)
        }
    }

    func isBrowserBundle(_ bid: String) -> Bool {
        browsers.contains { $0.bundleID == bid }
    }

    func seek(bundleID: String, to seconds: Double) {
        guard let appName = browsers.first(where: { $0.bundleID == bundleID })?.appName else { return }
        let s = String(format: "%.3f", seconds)
        if bundleID == "com.apple.Safari" {
            let script = "var app = Application(\"Safari\"); if (app.documents.length>0) { var doc=app.documents[0]; try { app.doJavaScript(\"var v=document.querySelector('video'); if(v) v.currentTime=\(s);\", {in: doc}); } catch(e) {} }"
            _ = runJXA(script, timeout: 2)
        } else {
            let script = "var app = Application(\"\(appName)\"); try { var tab=app.windows[0].activeTab; tab.execute({javascript: \"var v=document.querySelector('video'); if(v) v.currentTime=\(s);\"}); } catch(e) {}"
            _ = runJXA(script, timeout: 2)
        }
    }

    // Exposé pour PlaybackMonitor si besoin
    func runJXAForControl(_ script: String) -> String? {
        return runJXA(script, timeout: 2)
    }
}
