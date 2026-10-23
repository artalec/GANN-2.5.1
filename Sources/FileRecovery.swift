import Foundation

/// Поиск пропавшего файла трека по всему компьютеру.
///
/// Порядок: сначала Spotlight (быстро, если индекс включён), затем обход
/// домашней папки и подключённых дисков (работает и без индекса).
/// Совпадением считаются имя, размер и SHA-256. Каждый шаг пишется в журнал
/// с префиксом "DJPlayer recovery:", чтобы было видно, почему замена не случилась.
enum FileRecovery {

    struct Match {
        let url: URL
        let fingerprint: FileFingerprint
    }

    static func log(_ message: String) {
        NSLog("DJPlayer recovery: %@", message)
    }

    /// macOS может хранить одно и то же имя в разных Unicode-формах (кириллица, «й», «ё»).
    /// Сравниваем в одной форме, иначе одинаковые на вид имена не совпадут.
    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    /// Пути, которые не имеет смысла обходить: системные библиотеки и корзина.
    private static func isSkippedPath(_ path: String) -> Bool {
        path.contains("/Library/") || path.contains("/.Trash/") || path.contains("/node_modules/")
    }

    static func find(name: String, size: Int64, hash: String, excluding oldPath: String) -> Match? {
        let target = normalized(name)

        // 1. Spotlight.
        let spot = spotlightMatches(name: target)
        log("Spotlight: кандидатов по имени «\(name)» — \(spot.count)")
        if let m = check(spot, target: target, size: size, hash: hash, excluding: oldPath) {
            return m
        }

        // 2. Обход домашней папки и томов. Медленнее, но не зависит от индекса.
        var roots = [FileManager.default.homeDirectoryForCurrentUser]
        let volumes = URL(fileURLWithPath: "/Volumes")
        if let mounted = try? FileManager.default.contentsOfDirectory(at: volumes,
                                                                     includingPropertiesForKeys: nil) {
            roots.append(contentsOf: mounted)
        }
        var walked = 0
        var walkCandidates: [URL] = []
        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in en {
                if isSkippedPath(url.path) { en.skipDescendants(); continue }
                walked += 1
                guard normalized(url.lastPathComponent) == target else { continue }
                walkCandidates.append(url)
            }
        }
        log("обход: просмотрено \(walked) файлов, совпало по имени — \(walkCandidates.count)")
        return check(walkCandidates, target: target, size: size, hash: hash, excluding: oldPath)
    }

    /// Проверяет кандидатов: имя → размер → хэш. Хэш считаем только при совпадении размера.
    private static func check(_ urls: [URL], target: String, size: Int64, hash: String,
                              excluding oldPath: String) -> Match? {
        for url in urls {
            guard url.path != oldPath, normalized(url.lastPathComponent) == target else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let s = attrs[.size] as? NSNumber else { continue }
            guard s.int64Value == size else {
                log("«\(url.lastPathComponent)» найден, но размер другой (\(s.int64Value) ≠ \(size)) — пропуск")
                continue
            }
            guard let fp = FileFingerprint.compute(path: url.path) else {
                log("«\(url.path)»: не удалось прочитать файл")
                continue
            }
            if fp.sha256 == hash {
                log("совпадение по хэшу: \(url.path)")
                return Match(url: url, fingerprint: fp)
            }
            log("«\(url.path)»: размер совпал, хэш другой — это не та копия")
        }
        return nil
    }

    /// Кандидаты по имени через Spotlight. Ошибки не глотаем: пишем в журнал.
    private static func spotlightMatches(name: String) -> [URL] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-name", name]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            log("mdfind не запустился: \(error.localizedDescription)")
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            log("mdfind завершился с кодом \(p.terminationStatus): \(String(decoding: errData, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }
}
