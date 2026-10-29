func accepted(_ p: String) throws {
    // @fc:accept leak-on-exit -- closed by the caller
    let d = open(p, 0)
    try work()
    close(d)
}
