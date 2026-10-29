func leaks(_ p: String) throws {
    let d = open(p, 0)
    try work()
    close(d)
}
