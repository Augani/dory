// Unit-only process-relaunch and clock-resolution checks against the actual app source.
@main
struct CommandSequenceCheck {
    static func main() {
        var original = DoryDisplayCommandSequence()
        precondition(original.next(uptimeNanoseconds: 1000) == 1000)
        precondition(original.next(uptimeNanoseconds: 1000) == 1001)
        precondition(original.next(uptimeNanoseconds: 999) == 1002)
        var relaunched = DoryDisplayCommandSequence()
        let after = relaunched.next(uptimeNanoseconds: 2000)!
        precondition(after > original.lastSequence)
        precondition(relaunched.next(uptimeNanoseconds: 0) == nil)
        precondition(relaunched.next(uptimeNanoseconds: .max) == nil)
        var nearLimit = DoryDisplayCommandSequence()
        precondition(nearLimit.next(uptimeNanoseconds: .max - 1) == .max - 1)
        precondition(nearLimit.next(uptimeNanoseconds: .max - 1) == nil)
        print("App display command sequence checks passed")
    }
}
