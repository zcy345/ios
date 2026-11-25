import Foundation

/// 剪贴板里的文件（见 `airhand_link::files`）：
/// * 对方复制的文件：提示一下，点“保存到‘文件’”时才向对方取（复制时只发清单），放在 App 的“文稿/Airhand”里，
///   “文件” App 的“我的 iPhone › Airhand”能看到；
/// * 本机的文件（菜单 → 发送文件）：打开文件交给 Rust，公告给对方，对方粘贴时才来取。
enum ClipFiles {
    static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Airhand", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func received(key: Int64, items: [JSON]) {
        Native.filesReady(key)
        AppModel.shared.show(L.t("files_received", items.count), action: L.t("files_save")) {
            save(key: key, items: items)
        }
    }

    static func save(key: Int64, items: [JSON]) {
        AppModel.shared.show(L.t("files_saving"))
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for item in items {
                let path = item.strings("path")
                guard let name = path.last else { continue }
                do {
                    try saveEntry(key: key, path: path, kind: item.str("kind") ?? "file", size: item.int("size") ?? 0,
                                  mtime: item.int("mtime"), to: folder.appendingPathComponent(unique(name)))
                } catch {
                    Log.warn("couldn't save \(name): \(error)")
                    failed.append(name)
                }
            }
            DispatchQueue.main.async {
                AppModel.shared.show(failed.isEmpty ? L.t("files_saved") : L.t("files_failed", failed.joined(separator: ", ")))
            }
        }
    }

    struct FileFailure: Error { let code: Int64 }

    private static func saveEntry(key: Int64, path: [String], kind: String, size: Int, mtime: Int?, to dst: URL) throws {
        switch kind {
        case "dir":
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            let r = Json.parse(Native.filesList(key, Json.string(path), recursive: true))
            if let e = r?.str("error") { throw NSError(domain: "airhand", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
            for entry in (r?.arr("entries") ?? []).compactMap({ $0 as? JSON }) {
                let rel = entry.strings("path")
                guard !rel.isEmpty, rel.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." && !$0.contains("/") }) else { continue }
                let target = rel.reduce(dst) { $0.appendingPathComponent($1) }
                switch entry.str("kind") {
                case "dir": try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                case "file":
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try download(key: key, path: path + rel, size: entry.int("size") ?? 0, mtime: entry.int("mtime"), to: target)
                default: break
                }
            }
        case "file":
            try download(key: key, path: path, size: size, mtime: mtime, to: dst)
        default: break
        }
    }

    private static func download(key: Int64, path: [String], size: Int, mtime: Int?, to dst: URL) throws {
        let f = Native.filesOpen(key, Json.string(path), size: Int64(size), mtime: Int64(mtime ?? -1))
        guard f != 0 else { throw FileFailure(code: 0) }
        defer { Native.filesClose(f) }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let h = try FileHandle(forWritingTo: dst)
        defer { try? h.close() }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var offset: Int64 = 0
        while true {
            let n = buf.withUnsafeMutableBytes { Native.filesRead(f, offset: offset, into: $0) }
            if n < 0 { throw FileFailure(code: n) }
            if n == 0 { break }
            h.write(Data(buf[0..<Int(n)]))
            offset += n
        }
        if let mtime {
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(mtime) / 1000)], ofItemAtPath: dst.path)
        }
    }

    /// 同名的文件已经有了：加上 (2)、(3)……
    private static func unique(_ name: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for i in 2..<1000 {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(n).path) { return n }
        }
        return UUID().uuidString + "-" + name
    }

    /// 把选好的文件公告给对方（文件描述符交给 Rust，由它关）
    static func offer(_ urls: [URL], to session: RemoteSession) {
        var files: [JSON] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { continue }
            var st = stat()
            fstat(fd, &st)
            guard (st.st_mode & S_IFMT) == S_IFREG else { close(fd); continue }
            let mtime = UInt64(st.st_mtimespec.tv_sec) * 1000
            files.append(["name": url.lastPathComponent, "size": Int(st.st_size), "mtime": mtime, "fd": fd])
        }
        guard !files.isEmpty else { return }
        if session.offerFiles(files) { AppModel.shared.show(L.t("files_sent")) }
    }
}
