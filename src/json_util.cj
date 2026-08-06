package refine

import stdx.encoding.json.stream.*
import std.io.{ByteBuffer, readToEnd}

// ─── M8-Json: struct → JSON 文本 helper ─────────────────────────────────────
// 宏层生成代码调用（jsonToString / stringToJson），编译期强制 T 实现
// stdx json.stream 接口：T <: JsonSerializable（写） / T <: JsonDeserializable<T>（读）。
// struct 未实现接口 → 编译失败，比运行时注册表更强的保障。

public func jsonToString<T>(v: T): String where T <: JsonSerializable {
    let buf = ByteBuffer()
    let w = JsonWriter(buf)
    w.writeValue(v)
    w.flush()
    String.fromUtf8(readToEnd(buf))
}

public func stringToJson<T>(s: String): T where T <: JsonDeserializable<T> {
    let buf = ByteBuffer()
    unsafe { buf.write(s.rawData()) }
    let r = JsonReader(buf)
    T.fromJson(r)
}
