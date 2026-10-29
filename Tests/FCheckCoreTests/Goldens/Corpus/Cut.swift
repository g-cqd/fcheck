func cut(_ data: [UInt8]) -> String {
    String(decoding: data.prefix(16), as: UTF8.self)
}
