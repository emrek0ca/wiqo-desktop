using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using RovaWindows.Native;

namespace RovaWindows.Operations;

/// Desktop and local file work (MacSystem+Files): the same limits (200 KB desktop text, 512 KB
/// local read, 25 MB transfer), the same "never overwrite or recurse unless asked" rules, no
/// operation through a symlink/junction, and deletes go to the Recycle Bin so they can be undone.
internal static class FileOperations
{
    private const int MaxDesktopReadBytes = 200_000;
    private const int MaxLocalReadBytes = 512 * 1024;
    internal const long MaxTransferBytes = 25L * 1024 * 1024;

    internal static Outcome SaveTextFile(TextFilePayload payload)
    {
        var path = DesktopEntry(payload.Filename);
        if (path is null) return Outcome.Fail("INVALID_FILENAME", "Dosya adı geçersiz.");
        if (File.Exists(path) || Directory.Exists(path)) return Outcome.Fail("FILE_EXISTS", "Aynı adlı dosya zaten var; üzerine yazılmadı.");
        try
        {
            WriteAtomically(path, Encoding.UTF8.GetBytes(payload.Content));
            return Outcome.Ok($"{payload.Filename} masaüstüne kaydedildi.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_WRITE_FAILED", "Dosya yazılamadı.", error); }
    }

    internal static Outcome ListDesktop()
    {
        try
        {
            var desktop = WindowsPaths.Desktop;
            var entries = new DirectoryInfo(desktop).EnumerateFileSystemInfos()
                .Where(info => (info.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0 && WindowsValidation.IsValidDesktopFilename(info.Name))
                .OrderBy(info => info.Name, StringComparer.CurrentCultureIgnoreCase)
                .Take(100)
                .Select(info => new { filename = info.Name, byteCount = info is FileInfo file ? file.Length : 0, modifiedAt = info.LastWriteTimeUtc, isDirectory = info is DirectoryInfo })
                .ToArray();
            return Outcome.WithData("desktopFiles", entries, $"Masaüstünde {entries.Length} öğe bulundu.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("DESKTOP_LIST_FAILED", "Masaüstü dosyaları listelenemedi.", error); }
    }

    internal static Outcome ReadDesktop(string filename)
    {
        var path = DesktopEntry(filename);
        if (path is null || !File.Exists(path) || IsReparsePoint(path)) return Outcome.Fail("FILE_NOT_FOUND", "Masaüstünde bu dosya bulunamadı.");
        try
        {
            if (new FileInfo(path).Length > MaxDesktopReadBytes) return Outcome.Fail("FILE_TOO_LARGE", "Yalnızca 200 KB veya daha küçük metin dosyaları okunabilir.");
            var text = ReadUtf8(path);
            if (text is null) return Outcome.Fail("FILE_READ_FAILED", "Dosya metin olarak okunamadı.");
            return Outcome.WithData("fileContent", new { filename, content = text }, $"{filename} okundu.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_READ_FAILED", "Dosya okunamadı.", error); }
    }

    internal static Outcome MoveDesktop(FileMovePayload payload, bool rename)
    {
        var source = DesktopEntry(payload.Source);
        var destination = DesktopEntry(payload.Destination);
        if (source is null || destination is null || !File.Exists(source) || IsReparsePoint(source)) return Outcome.Fail("FILE_NOT_FOUND", "Kaynak dosya masaüstünde bulunamadı.");
        if (File.Exists(destination) || Directory.Exists(destination)) return Outcome.Fail("FILE_EXISTS", "Hedef dosya zaten var; üzerine yazılmadı.");
        try
        {
            File.Move(source, destination);
            return Outcome.Ok(rename ? "Dosya yeniden adlandırıldı." : "Dosya taşındı.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_MOVE_FAILED", "Dosya taşınamadı veya yeniden adlandırılamadı.", error); }
    }

    internal static Outcome List(LocalFileOperationPayload payload)
    {
        var directory = Resolve(payload.Path);
        if (directory is null || !Directory.Exists(directory)) return Outcome.Fail(File.Exists(directory ?? "") ? "NOT_A_DIRECTORY" : "FILE_NOT_FOUND", File.Exists(directory ?? "") ? "İstenen yol bir klasör değil." : "İstenen klasör bulunamadı.");
        try
        {
            var entries = new DirectoryInfo(directory).EnumerateFileSystemInfos()
                .Where(info => (info.Attributes & FileAttributes.Hidden) == 0 && info.LinkTarget is null)
                .OrderBy(info => info.Name, StringComparer.CurrentCultureIgnoreCase)
                .Skip(Math.Max(0, payload.Page) * Math.Max(1, payload.PageSize))
                .Take(Math.Max(1, payload.PageSize))
                .Select(Entry)
                .ToArray();
            return Outcome.WithData("files", entries, $"{entries.Length} dosya bulundu.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_LIST_FAILED", "Klasör içeriği listelenemedi.", error); }
    }

    internal static Outcome Read(LocalFileOperationPayload payload)
    {
        var path = Resolve(payload.Path);
        if (path is null || !File.Exists(path)) return Outcome.Fail(Directory.Exists(path ?? "") ? "FILE_NOT_REGULAR" : "FILE_NOT_FOUND", Directory.Exists(path ?? "") ? "Yalnızca normal dosyalar okunabilir." : "İstenen dosya bulunamadı.");
        try
        {
            if (new FileInfo(path).Length > MaxLocalReadBytes)
                return Outcome.Fail("FILE_TOO_LARGE", "Bu dosya tek yanıt için çok büyük; daha küçük bir dosya veya sayfalı belge okuma kullan.");
            var bytes = File.ReadAllBytes(path);
            var mime = MimeType(path);
            var text = DecodeUtf8(bytes);
            object value = text is not null
                ? new { path, mimeType = mime, text, truncated = false }
                : new { path, mimeType = mime, base64 = Convert.ToBase64String(bytes), truncated = false };
            return Outcome.WithData("fileData", value, "Dosya okundu.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_READ_FAILED", "Dosya okunamadı.", error); }
    }

    internal static Outcome Write(LocalFileOperationPayload payload)
    {
        var destination = Resolve(payload.Path, allowMissingLast: true);
        if (payload.Content is null || destination is null || !Directory.Exists(Path.GetDirectoryName(destination)))
            return Outcome.Fail("INVALID_FILE_PATH", "Dosya yolu veya hedef klasör geçersiz.");
        if (Directory.Exists(destination)) return Outcome.Fail("INVALID_FILE_PATH", "Hedef bir klasör; dosya yolu ver.");
        if (File.Exists(destination) && !payload.Overwrite) return Outcome.Fail("FILE_EXISTS", "Aynı dosya zaten var; üzerine yazma onayı verilmedi.", "permission");
        try
        {
            WriteAtomically(destination, Encoding.UTF8.GetBytes(payload.Content));
            return Outcome.Ok("Dosya yazıldı.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_WRITE_FAILED", "Dosya yazılamadı.", error); }
    }

    internal static Outcome Transfer(LocalFileOperationPayload payload, bool copy)
    {
        var source = Resolve(payload.Path);
        var destination = payload.Destination is null ? null : Resolve(payload.Destination, allowMissingLast: true);
        if (source is null || destination is null || !(File.Exists(source) || Directory.Exists(source)) || !Directory.Exists(Path.GetDirectoryName(destination)))
            return Outcome.Fail("INVALID_FILE_PATH", "Kaynak, hedef veya hedef klasör geçersiz.");
        var isDirectory = Directory.Exists(source);
        if (isDirectory && !payload.Recursive) return Outcome.Fail("RECURSIVE_REQUIRED", "Klasör işlemi için recursive=true açıkça belirtilmeli.", "permission");
        if (isDirectory && IsWithin(destination, source)) return Outcome.Fail("INVALID_FILE_PATH", "Bir klasör kendi içine taşınamaz veya kopyalanamaz.");
        if (File.Exists(destination) || Directory.Exists(destination))
        {
            if (!payload.Overwrite) return Outcome.Fail("FILE_EXISTS", "Hedef zaten var; üzerine yazma onayı verilmedi.", "permission");
            if (IsReparsePoint(destination)) return Outcome.Fail("SYMLINK_REJECTED", "Sembolik bağlantılar üzerinden dosya işlemi yapılmadı.", "permission");
        }
        try
        {
            if (copy)
            {
                if (isDirectory) CopyDirectory(source, destination, payload.Overwrite);
                else File.Copy(source, destination, payload.Overwrite);
            }
            else if (isDirectory)
            {
                if (Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
                Directory.Move(source, destination);
            }
            else File.Move(source, destination, payload.Overwrite);
            return Outcome.Ok(copy ? "Dosya kopyalandı." : "Dosya taşındı.");
        }
        catch (Exception error) when (IsFileError(error)) { return FileError(copy ? "FILE_COPY_FAILED" : "FILE_MOVE_FAILED", copy ? "Dosya kopyalanamadı." : "Dosya taşınamadı.", error); }
    }

    /// To the Recycle Bin, never a permanent delete; drive roots, the profile and system folders
    /// are refused outright.
    internal static Outcome Delete(LocalFileOperationPayload payload)
    {
        var target = Resolve(payload.Path);
        if (target is null || !(File.Exists(target) || Directory.Exists(target))) return Outcome.Fail("FILE_NOT_FOUND", "Silinecek dosya bulunamadı.");
        if (IsProtected(target)) return Outcome.Fail("PROTECTED_PATH", "Sistem veya kullanıcı kök klasörü silinemez.", "permission");
        if (Directory.Exists(target) && !payload.Recursive) return Outcome.Fail("RECURSIVE_REQUIRED", "Klasör silmek için recursive=true açıkça belirtilmeli.", "permission");
        var operation = new NativeMethods.ShFileOpStruct
        {
            Function = NativeMethods.FoDelete,
            From = target + "\0\0",
            Flags = NativeMethods.FofAllowUndo | NativeMethods.FofNoConfirmation | NativeMethods.FofSilent | NativeMethods.FofNoErrorUi
        };
        var code = NativeMethods.SHFileOperation(ref operation);
        if (code != 0 || operation.AnyOperationsAborted || File.Exists(target) || Directory.Exists(target))
            return Outcome.Fail("FILE_DELETE_FAILED", "Dosya Geri Dönüşüm Kutusu'na taşınamadı; kullanımda olabilir.");
        return Outcome.Ok("Dosya Geri Dönüşüm Kutusu'na taşındı.");
    }

    internal static async Task<Outcome> SaveArtifact(ArtifactFilePayload payload, Func<CancellationToken, Task<string?>> accessToken, HttpClient http, CancellationToken cancellationToken)
    {
        var path = DesktopEntry(payload.Filename);
        if (path is null) return Outcome.Fail("INVALID_FILENAME", "Dosya adı geçersiz.");
        if ((File.Exists(path) || Directory.Exists(path)) && !payload.Overwrite) return Outcome.Fail("FILE_EXISTS", "Masaüstünde aynı adlı dosya var; üzerine yazılmadı.");
        var token = await accessToken(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(token)) return Outcome.Fail("BACKEND_AUTH_REQUIRED", "Artifact indirmek için Wiqo oturumu gerekli.");
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, payload.DownloadUrl);
            request.Headers.Authorization = new("Bearer", token);
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode || response.Content.Headers.ContentType?.MediaType == "application/json")
                return Outcome.Fail("ARTIFACT_DOWNLOAD_FAILED", "Artifact backend'den indirilemedi.");
            if (response.Content.Headers.ContentLength > MaxTransferBytes) return Outcome.Fail("ARTIFACT_TOO_LARGE", "İndirilen dosya desteklenen boyut sınırını aşıyor.");
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var buffer = new MemoryStream();
            var chunk = new byte[81_920];
            int read;
            while ((read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
            {
                if (buffer.Length + read > MaxTransferBytes) return Outcome.Fail("ARTIFACT_TOO_LARGE", "İndirilen dosya desteklenen boyut sınırını aşıyor.");
                buffer.Write(chunk, 0, read);
            }
            var data = buffer.ToArray();
            if (payload.ByteCount is { } expected && data.LongLength != expected) return Outcome.Fail("ARTIFACT_INTEGRITY_FAILED", "İndirilen artifact boyut doğrulamasından geçmedi.");
            if (payload.Sha256 is { } digest && !Convert.ToHexString(SHA256.HashData(data)).Equals(digest, StringComparison.OrdinalIgnoreCase))
                return Outcome.Fail("ARTIFACT_INTEGRITY_FAILED", "İndirilen artifact bütünlük doğrulamasından geçmedi.");
            WriteAtomically(path, data);
            return Outcome.Ok($"{payload.Filename} masaüstüne kaydedildi.");
        }
        catch (HttpRequestException) { return Outcome.Fail("ARTIFACT_DOWNLOAD_FAILED", "Artifact indirilemedi.", "network"); }
        catch (Exception error) when (IsFileError(error)) { return FileError("FILE_WRITE_FAILED", "Artifact masaüstüne yazılamadı.", error); }
    }

    internal static Outcome? ValidateTransferSource(LocalFileOperationPayload payload, out string path)
    {
        path = Resolve(payload.Path) ?? "";
        if (path.Length == 0 || !File.Exists(path)) return Outcome.Fail("INVALID_FILE", "Dosya bulunamadı veya erişilemiyor.");
        var length = new FileInfo(path).Length;
        if (length is < 1 or > MaxTransferBytes) return Outcome.Fail("FILE_TOO_LARGE", "Yalnızca 25 MB veya daha küçük normal dosyalar gönderilebilir.");
        return null;
    }

    /// "~\x" is the profile; the final entry must not be a symlink or junction; with
    /// allowMissingLast the parent must exist (for writes and move targets).
    internal static string? Resolve(string rawPath, bool allowMissingLast = false)
    {
        if (!WindowsValidation.IsValidLocalPath(rawPath)) return null;
        var raw = rawPath.Trim();
        if (raw.StartsWith("~\\", StringComparison.Ordinal) || raw.StartsWith("~/", StringComparison.Ordinal)) raw = Path.Combine(WindowsPaths.UserProfile, raw[2..]);
        string full;
        try { full = Path.GetFullPath(raw).TrimEnd('\\', '/'); }
        catch { return null; }
        if (full.Length == 2 && full[1] == ':') full += "\\";
        if (File.Exists(full) || Directory.Exists(full)) return IsReparsePoint(full) ? null : full;
        if (!allowMissingLast) return null;
        var parent = Path.GetDirectoryName(full);
        return parent is not null && Directory.Exists(parent) && !IsReparsePoint(parent) ? full : null;
    }

    private static string? DesktopEntry(string filename)
    {
        if (!WindowsValidation.IsValidDesktopFilename(filename)) return null;
        var desktop = WindowsPaths.Desktop;
        var path = Path.GetFullPath(Path.Combine(desktop, filename.Trim()));
        return string.Equals(Path.GetDirectoryName(path), Path.GetFullPath(desktop).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? path : null;
    }

    private static object Entry(FileSystemInfo info) => new
    {
        path = info.FullName,
        name = info.Name,
        fileType = info is FileInfo file ? file.Extension.TrimStart('.').ToLowerInvariant() : null,
        byteCount = info is FileInfo sized ? sized.Length : 0,
        modifiedAt = info.LastWriteTimeUtc,
        isDirectory = info is DirectoryInfo
    };

    private static bool IsProtected(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd('\\');
        if (full.Length <= 3) return true;
        var protectedRoots = new[]
        {
            WindowsPaths.UserProfile, Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), Path.GetDirectoryName(WindowsPaths.UserProfile) ?? "",
            WindowsPaths.Desktop, Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), WindowsPaths.RoamingDirectory
        };
        return protectedRoots.Where(root => root.Length > 0).Any(root => string.Equals(full, Path.GetFullPath(root).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) ||
               IsWithin(full, Environment.GetFolderPath(Environment.SpecialFolder.Windows));
    }

    internal static bool IsWithin(string path, string root)
    {
        var full = Path.GetFullPath(path).TrimEnd('\\');
        var boundary = Path.GetFullPath(root).TrimEnd('\\');
        return full.Equals(boundary, StringComparison.OrdinalIgnoreCase) || full.StartsWith(boundary + "\\", StringComparison.OrdinalIgnoreCase);
    }

    private static void CopyDirectory(string source, string destination, bool overwrite)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
        {
            if (IsReparsePoint(file)) continue;
            File.Copy(file, Path.Combine(destination, Path.GetFileName(file)), overwrite);
        }
        foreach (var directory in Directory.EnumerateDirectories(source))
        {
            if (IsReparsePoint(directory)) continue;
            CopyDirectory(directory, Path.Combine(destination, Path.GetFileName(directory)), overwrite);
        }
    }

    internal static void WriteAtomically(string path, byte[] data)
    {
        var temporary = path + ".wiqo-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, data);
            File.Move(temporary, path, true);
        }
        finally { try { File.Delete(temporary); } catch { } }
    }

    /// Symlinks and junctions only; OneDrive cloud files are reparse points too and stay usable.
    internal static bool IsReparsePoint(string path) => PathSafety.IsLink(path);

    private static string? ReadUtf8(string path) => DecodeUtf8(File.ReadAllBytes(path));

    private static string? DecodeUtf8(byte[] bytes)
    {
        try
        {
            var text = new UTF8Encoding(false, true).GetString(bytes);
            return text.StartsWith('﻿') ? text[1..] : text;
        }
        catch (DecoderFallbackException) { return null; }
    }

    internal static string MimeType(string path) => Path.GetExtension(path).ToLower(CultureInfo.InvariantCulture) switch
    {
        ".txt" or ".log" => "text/plain", ".md" => "text/markdown", ".csv" => "text/csv", ".json" => "application/json",
        ".html" or ".htm" => "text/html", ".xml" => "application/xml", ".pdf" => "application/pdf", ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp", ".zip" => "application/zip",
        ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream"
    };

    private static bool IsFileError(Exception error) => error is IOException or UnauthorizedAccessException or System.Security.SecurityException or NotSupportedException or ArgumentException;

    private static Outcome FileError(string code, string fallback, Exception error) => error is UnauthorizedAccessException or System.Security.SecurityException
        ? Outcome.Fail("ACCESS_DENIED", "Wiqo'nun bu dosyaya veya klasöre erişim izni yok (yönetici izni ya da Denetimli Klasör Erişimi engelliyor olabilir).", "permission")
        : Outcome.Fail(code, fallback);
}
