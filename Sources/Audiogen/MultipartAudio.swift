import Foundation

struct MultipartAudio: Sendable {
    let url: URL
    let boundary: String
}
actor MultipartBuilder {
    func build(fields: [String: String], files: [(field: String, url: URL)]) throws -> MultipartAudio {
        let boundary = "Audiogen-" + UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        do {
            func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            for key in fields.keys.sorted() {
                try Task.checkCancellation()
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
            }
            for file in files {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.field).wav\"\r\nContent-Type: audio/wav\r\n\r\n")
                let input = try FileHandle(forReadingFrom: file.url)
                do {
                    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: chunk) }
                    try input.close()
                } catch { try? input.close(); throw error }
                try write("\r\n")
            }
            try write("--\(boundary)--\r\n")
            try output.close()
            return MultipartAudio(url: url, boundary: boundary)
        } catch { try? output.close(); try? FileManager.default.removeItem(at: url); throw error }
    }
}
