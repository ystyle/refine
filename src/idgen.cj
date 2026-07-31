package refine

import std.random.Random
import sonyflake.*
import opencj::ulid.*

public interface IdGenerator {
    func generate(): String
}

public class RandomIdGenerator <: IdGenerator {
    private let rng = Random()

    public func generate(): String {
        let hexChars = "0123456789abcdef"
        var id = ""
        for (i in 0..36) {
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                id = id + "-"
            } else if (i == 14) {
                id = id + "4"
            } else if (i == 19) {
                let v = Int64(rng.nextUInt64() % 4)
                if (v == 0) { id = id + "8" }
                else if (v == 1) { id = id + "9" }
                else if (v == 2) { id = id + "a" }
                else { id = id + "b" }
            } else {
                let idx = rng.nextUInt64() % 16
                id = id + hexChars[Int64(idx)..Int64(idx) + 1]
            }
        }
        id
    }
}

public class SonyflakeIdGenerator <: IdGenerator {
    private let sf: Sonyflake

    public init() {
        let rng = Random()
        let machineId = UInt16(rng.nextUInt64() % 65536)
        let st = Setting(machineId)
        this.sf = Sonyflake(st)
    }

    public func generate(): String {
        this.sf.NextID().toString()
    }
}

public class UlidIdGenerator <: IdGenerator {
    public init() {}

    public func generate(): String {
        nextId()
    }
}
