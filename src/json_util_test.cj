package refine

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.{ArrayList, HashMap}
import stdx.encoding.json.stream.*

// ─── M8-Json: json_util.cj helper（jsonToString / stringToJson）单测 ────────────
// fixture 结构实现 stdx json.stream 接口，验证泛型约束（T <: JsonSerializable /
// T <: JsonDeserializable<T>）的序列化/反序列化 roundtrip，含嵌套 Option/集合/中文。

public struct JsonAddress <: JsonSerializable & JsonDeserializable<JsonAddress> {
    public var city: String = ""
    public var zip: Int64 = 0

    public init() {}

    public init(city: String, zip: Int64) {
        this.city = city
        this.zip = zip
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("city").writeValue(this.city)
        w.writeName("zip").writeValue(this.zip)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): JsonAddress {
        var res = JsonAddress()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "city" => res.city = r.readValue<String>()
                case "zip" => res.zip = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct JsonProfile <: JsonSerializable & JsonDeserializable<JsonProfile> {
    public var name: String = ""
    public var age: Int64 = 0
    public var tags: ArrayList<String> = ArrayList<String>()
    public var address: Option<JsonAddress> = None
    public var meta: HashMap<String, String> = HashMap()

    public init() {}

    public init(name: String, age: Int64, tags: ArrayList<String>, address: Option<JsonAddress>, meta: HashMap<String, String>) {
        this.name = name
        this.age = age
        this.tags = tags
        this.address = address
        this.meta = meta
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("age").writeValue(this.age)
        w.writeName("tags").writeValue(this.tags)
        w.writeName("address").writeValue(this.address)
        w.writeName("meta").writeValue(this.meta)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): JsonProfile {
        var res = JsonProfile()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "name" => res.name = r.readValue<String>()
                case "age" => res.age = r.readValue<Int64>()
                case "tags" => res.tags = r.readValue<ArrayList<String>>()
                case "address" => res.address = r.readValue<Option<JsonAddress>>()
                case "meta" => res.meta = r.readValue<HashMap<String, String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

func newJsonProfile(): JsonProfile {
    let tags = ArrayList<String>()
    tags.add("go")
    tags.add("rust")
    let meta = HashMap<String, String>()
    meta.add("k1", "v1")
    meta.add("k2", "v2")
    JsonProfile("Alice", 30, tags, Some(JsonAddress("Beijing", 100000)), meta)
}

@Test
public class JsonUtilTest {
    @TestCase
    public func testJsonToStringSerializesFields(): Unit {
        let p = newJsonProfile()
        let s = jsonToString(p)
        @Expect(s.contains("\"name\":\"Alice\""), true)
        @Expect(s.contains("\"age\":30"), true)
        @Expect(s.contains("\"tags\":[\"go\",\"rust\"]"), true)
        @Expect(s.contains("\"city\":\"Beijing\""), true)
        @Expect(s.contains("\"zip\":100000"), true)
        @Expect(s.contains("\"k1\":\"v1\""), true)
    }

    @TestCase
    public func testStringToJsonDeserializesFields(): Unit {
        let json = ##"{"name":"Bob","age":25,"tags":["a","b"],"address":{"city":"Shanghai","zip":200000},"meta":{"k":"v"}}"##
        let p = stringToJson<JsonProfile>(json)
        @Expect(p.name, "Bob")
        @Expect(p.age, 25)
        @Expect(p.tags.size, 2)
        @Expect(p.tags[0], "a")
        @Expect(p.tags[1], "b")
        match (p.address) {
            case Some(a) =>
                @Expect(a.city, "Shanghai")
                @Expect(a.zip, 200000)
            case None => @Fail("expected Some address")
        }
        match (p.meta.get("k")) {
            case Some(v) => @Expect(v, "v")
            case None => @Fail("expected meta key k")
        }
    }

    @TestCase
    public func testRoundtripFull(): Unit {
        let p = newJsonProfile()
        let back = stringToJson<JsonProfile>(jsonToString(p))
        @Expect(back.name, p.name)
        @Expect(back.age, p.age)
        @Expect(back.tags.size, p.tags.size)
        @Expect(back.tags[0], p.tags[0])
        @Expect(back.tags[1], p.tags[1])
        match (back.address) {
            case Some(a) =>
                match (p.address) {
                    case Some(orig) =>
                        @Expect(a.city, orig.city)
                        @Expect(a.zip, orig.zip)
                    case None => @Fail("expected original Some address")
                }
            case None => @Fail("expected Some address after roundtrip")
        }
        @Expect(back.meta.size, p.meta.size)
        @Expect(back.meta.get("k1").getOrThrow(), p.meta.get("k1").getOrThrow())
        @Expect(back.meta.get("k2").getOrThrow(), p.meta.get("k2").getOrThrow())
    }

    @TestCase
    public func testRoundtripEmptyCollectionsAndNone(): Unit {
        let p = JsonProfile("Empty", 0, ArrayList<String>(), None, HashMap<String, String>())
        let back = stringToJson<JsonProfile>(jsonToString(p))
        @Expect(back.name, "Empty")
        @Expect(back.age, 0)
        @Expect(back.tags.size, 0)
        @Expect(back.meta.size, 0)
        match (back.address) {
            case Some(_) => @Fail("expected None address after roundtrip")
            case None => ()
        }
    }

    @TestCase
    public func testRoundtripChineseAndEscapeChars(): Unit {
        let tricky = "张三\n李四\"引号\"\\反斜杠"
        let p = JsonProfile(tricky, 20, ArrayList<String>(), None, HashMap<String, String>())
        let back = stringToJson<JsonProfile>(jsonToString(p))
        @Expect(back.name, tricky)
    }
}
