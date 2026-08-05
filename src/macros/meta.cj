macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func extractFields(cd: ClassDecl): ArrayList<FieldInfo> {
    let list = ArrayList<FieldInfo>()
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let typeStr = vd.declType.toTokens().toString()
                let fn = vd.identifier.value
                let isPk = (fn == "id")
                let autoInc = (fn == "id" && typeStr == "Int64")
                let info = FieldInfo(fn, typeStr, "", isPk, autoInc, false)
                list.add(info)
            case _ => ()
        }
    }
    list
}

func detectRelations(fields: ArrayList<FieldInfo>): ArrayList<RelInfo> {
    let result = ArrayList<RelInfo>()
    for (f in fields) {
        let tn = f.typeName
        // F4: Option<DateTime> 可空标量防御性排除（isRelationField 已放行；此处防
        // detectRelations 的 Option 分支把它误判成 ref_to 关系）。
        if (isNullableScalarType(tn)) { continue }
        if (tn.contains("Option<")) {
            let start = tn.indexOf("Option<").getOrThrow() + 7
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let byCol = f.name + "_id"
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_to", targetType, byCol, relFields, ""))
        } else if (tn.contains("ArrayList<")) {
            let start = tn.indexOf("ArrayList<").getOrThrow() + 10
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_many", targetType, "", relFields, f.name))
        } else if (tn.contains("Array<")) {
            // R-I8: Array<UInt8> 是一等存储类型 Bytes（typeNameToStorageType → StorageType.Bytes），
            // 不是 ref_many 集合。修复前被当作 ref_many → 生成 RefMany<UInt8> 引用
            // 不存在的 UInt8Schema/UInt8Rel → Bytes 实体字段不可达。
            // isBytesArrayType 归一化比较（toTokens().toString() 渲染泛型带空格）。
            if (isBytesArrayType(tn)) { continue }
            let start = tn.indexOf("Array<").getOrThrow() + 6
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_many", targetType, "", relFields, f.name))
        }
    }
    result
}


func mergeAnnotationRels(rels: ArrayList<RelInfo>, refMessages: ArrayList<MacroMessage>, relMessages: ArrayList<MacroMessage>): ArrayList<RelInfo> {
    let result = ArrayList<RelInfo>()
    for (r in rels) {
        if (!isFieldAnnotated(r.fieldName, refMessages, relMessages)) { result.add(r) }
    }
    for (m in refMessages) {
        let fieldName = m.getString("fieldName")
        let target = m.getString("target")
        let kind = m.getString("kind")
        let relFields = ArrayList<String>()
        if (m.hasItem("fields")) {
            let fs = m.getString("fields")
            for (name in fs.split("|")) { relFields.add(name) }
        } else {
            relFields.add("id")
        }
        if (kind == "ref_many") {
            let via = m.getString("via")
            result.add(RelInfo(fieldName, "ref_many", target, "", relFields, via))
        } else {
            let fk = m.getString("fk")
            result.add(RelInfo(fieldName, "ref_to", target, fk, relFields, ""))
        }
    }
    for (m in relMessages) {
        let fieldName = m.getString("fieldName")
        let kind = m.getString("kind")
        let target = m.getString("target")
        var viaOrBy = ""
        if (m.hasItem("via")) { viaOrBy = m.getString("via") }
        let relFields = ArrayList<String>()
        if (m.hasItem("fields")) {
            let fs = m.getString("fields")
            for (name in fs.split("|")) { relFields.add(name) }
        } else {
            relFields.add("id")
        }
        if (kind == "has_many" || kind == "has_one") {
            result.add(RelInfo(fieldName, kind, target, viaOrBy, relFields, ""))
        }
    }
    result
}


func applyIdAnnotations(fields: ArrayList<FieldInfo>, idMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    if (idMessages.size == 0) { return fields }
    var result = ArrayList<FieldInfo>()
    for (i in 0..fields.size) {
        var f = fields.get(i).getOrThrow()
        f.isPk = false; f.autoInc = false
        result.add(f)
    }
    for (m in idMessages) {
        let fieldName = m.getString("fieldName")
        var next = ArrayList<FieldInfo>()
        for (i in 0..result.size) {
            let f = result.get(i).getOrThrow()
            if (f.name == fieldName) {
                var updated = f
                updated.isPk = true
                if (m.hasItem("auto") && m.getString("auto") == "true" && f.typeName == "Int64") {
                    updated.autoInc = true
                }
                next.add(updated)
            } else { next.add(f) }
        }
        result = next
    }
    result
}


func applyAuditVersion(fields: ArrayList<FieldInfo>, versionMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    var result = ArrayList<FieldInfo>()
    var versionCount = 0
    for (f in fields) {
        var updated = f
        for (m in versionMessages) {
            if (m.getString("fieldName") == f.name) {
                if (f.typeName != "Int64") { throw Exception("@Version field must be Int64: " + f.name) }
                updated.isVersion = true
                versionCount++
            }
        }
        result.add(updated)
    }
    if (versionCount > 1) { throw Exception("entity can only have one @Version field") }
    result
}

func findAuditFields(fields: ArrayList<FieldInfo>): (Bool, Bool) {
    var hasCreatedAt = false
    var hasUpdatedAt = false
    for (f in fields) {
        if (f.name == "created_at" && f.typeName == "DateTime") { hasCreatedAt = true }
        if (f.name == "updated_at" && f.typeName == "DateTime") { hasUpdatedAt = true }
    }
    (hasCreatedAt, hasUpdatedAt)
}

func findVersionField(fields: ArrayList<FieldInfo>): String {
    for (f in fields) { if (f.isVersion) { return f.name } }
    ""
}



func buildAuditCreateTokens(fields: ArrayList<FieldInfo>, target: String): Tokens {
    let (hasCreatedAt, hasUpdatedAt) = findAuditFields(fields)
    let targetTok = Token(TokenKind.IDENTIFIER, target)
    var body = Tokens()
    if (hasCreatedAt) { body = body + quote($(targetTok).created_at = DateTime.now();) }
    if (hasUpdatedAt) {
        body = body + Token(TokenKind.NL)
        body = body + quote($(targetTok).updated_at = DateTime.now();)
    }
    body
}

func buildAuditUpdateTokens(fields: ArrayList<FieldInfo>, target: String): Tokens {
    let (_, hasUpdatedAt) = findAuditFields(fields)
    if (hasUpdatedAt) {
        let targetTok = Token(TokenKind.IDENTIFIER, target)
        quote($(targetTok).updated_at = DateTime.now();)
    } else { Tokens() }
}

func buildVersionInitTokens(fields: ArrayList<FieldInfo>, target: String): Tokens {
    let vname = findVersionField(fields)
    if (vname == "") { return Tokens() }
    let ident = Token(TokenKind.IDENTIFIER, vname)
    let targetTok = Token(TokenKind.IDENTIFIER, target)
    quote(
        if ($(targetTok).$(ident) == 0) { $(targetTok).$(ident) = 1 }
    )
}


func lowerTableName(name: String): String {
    if (name.size == 0) { return name }
    name[0..1].toAsciiLower() + name[1..]
}

func upperFirstLetter(name: String): String {
    if (name.size == 0) { return name }
    name[0..1].toAsciiUpper() + name[1..]
}

// R-I8: Array<UInt8> 是 Bytes 存储类型（一等标量），不是关系集合——关系检测白名单排除。
// detectRelations 与 isRelationField 共享此判定，保证 schema/insert/select/mapper
// 各路径把 Array<UInt8> 当普通字段处理（typeNameToStorageType → StorageType.Bytes）。
//
// 注意：`vd.declType.toTokens().toString()` 对泛型类型渲染带空格（实测 "Array < UInt8 >"、
// "Option < X >"、"ArrayList < X >"），故比较前必须归一化（去空格），
// 否则 "Array<UInt8>" 字面量永远匹配不上真实类型字符串。
func isBytesArrayType(typeName: String): Bool {
    typeName.replace(" ", "") == "Array<UInt8>"
}

// F4: Option<DateTime> 可空软删字段判定（方案 D1 方案 A：本迭代仅认 DateTime 可空标量）。
// 归一化（去空格）后精确匹配 Option<DateTime>——isBytesArrayType 先排除（Array<UInt8> 是
// Bytes 一等标量，非可空标量）。其余 Option<标量>（Option<Int64> 等）保持被 isRelationField
// 当关系字段跳过（历史行为，记档为后续功能）。
// Decimal: Option<Decimal> 可空标量判定扩展（用户决策，与 F4 同构）——schema nullable 列、
// insert Some/None 绑定、rowMapper getOrNull<Decimal>、pgCastTypeOf 解包均复用此判定。
func isNullableScalarType(typeName: String): Bool {
    if (isBytesArrayType(typeName)) { return false }
    let norm = typeName.replace(" ", "")
    norm == "Option<DateTime>" || norm == "Option<Decimal>"
}

// F4: 取 Option<X> 的内部类型 X（Option<DateTime> → "DateTime"）。调用方须先确认
// isNullableScalarType；格式不符时返回归一化原串（防御，不产生越界/空串）。
func unwrapOptionType(typeName: String): String {
    let norm = typeName.replace(" ", "")
    match (norm.indexOf("Option<")) {
        case Some(s) =>
            let end = norm.lastIndexOf(">").getOrThrow()
            norm[s + 7..end]
        case None => norm
    }
}

func isRelationField(typeName: String): Bool {
    if (isBytesArrayType(typeName)) { return false }
    if (isNullableScalarType(typeName)) { return false }
    typeName.contains("Option") || typeName.contains("ArrayList") || typeName.contains("Array")
}

func getPkFields(fields: ArrayList<FieldInfo>): ArrayList<FieldInfo> {
    let result = ArrayList<FieldInfo>()
    for (f in fields) { if (f.isPk) { result.add(f) } }
    result
}

func shouldSkipInInsert(f: FieldInfo): Bool {
    isRelationField(f.typeName) || (f.isPk && f.autoInc)
}

func isFieldAnnotated(fieldName: String, refMessages: ArrayList<MacroMessage>, relMessages: ArrayList<MacroMessage>): Bool {
    for (m in refMessages) {
        if (m.getString("fieldName") == fieldName) { return true }
    }
    for (m in relMessages) {
        if (m.getString("fieldName") == fieldName) { return true }
    }
    false
}

func typeNameToStorageType(typeName: String): String {
    // F4: Option<DateTime> 可空标量先解包再映射（→ StorageType.Timestamp）。
    // 修复前落在 Json 兜底（emitUnknownTypeWarnings 会误发 warning，见 M22）。
    var tn = typeName
    if (isNullableScalarType(tn)) { tn = unwrapOptionType(tn) }
    if (tn == "Int8" || tn == "Int16" || tn == "Int32" || tn == "Int64" ||
        tn == "UInt8" || tn == "UInt16" || tn == "UInt32" || tn == "UInt64") {
        "StorageType.Integer"
    } else if (tn == "Float32" || tn == "Float64") { "StorageType.Float"
    } else if (tn == "Bool") { "StorageType.`Bool`"
    } else if (tn == "String") { "StorageType.String"
    } else if (isBytesArrayType(tn)) { "StorageType.Bytes"
    } else if (tn == "DateTime") { "StorageType.Timestamp"
    } else if (tn == "Decimal") { "StorageType.Decimal"
    } else { "StorageType.Json" }
}

// M22 评审（Fix 3）: 字段落入 typeNameToStorageType 的 Json 兜底分支（未知 struct）
// 时，在宏展开期发编译期 WARNING。宏层未接线 TypeAdapter——这类字段写路径经
// dispatchSet 抛 RefineException（R-C2 起不再静默写 NULL）、读路径 result.get<T> 抛错，
// 编译期提示比运行时才暴露更友好。
func isJsonFallbackType(typeName: String): Bool {
    typeNameToStorageType(typeName) == "StorageType.Json"
}

func emitUnknownTypeWarnings(cd: ClassDecl, fields: ArrayList<FieldInfo>): Unit {
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fn = vd.identifier.value
                let typeStr = vd.declType.toTokens().toString()
                if (isRelationField(typeStr)) { continue }
                var storageOverride = ""
                for (f in fields) {
                    if (f.name == fn) { storageOverride = f.storageOverride; break }
                }
                // 用户显式 @Field[...] 覆盖过存储类型 = 知情选择，不警告
                if (storageOverride != "") { continue }
                if (isJsonFallbackType(typeStr)) {
                    diagReport(DiagReportLevel.WARNING, vd.toTokens(),
                        "entity field '" + fn + "' of type '" + typeStr + "' maps to StorageType.Json but has no TypeAdapter",
                        "writes throw RefineException and reads fail — implement refine.TypeAdapter<" + typeStr + "> or override with @Field[...]")
                }
            case _ => ()
        }
    }
}

func mergeFieldOverrides(fields: ArrayList<FieldInfo>, fieldMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    var result = ArrayList<FieldInfo>()
    for (fi in 0..fields.size) {
        var f = fields[fi]
        for (m in fieldMessages) {
            if (m.getString("fieldName") == f.name) { f.storageOverride = m.getString("storageType") }
        }
        result.add(f)
    }
    result
}

func getFieldTypeName(fields: ArrayList<FieldInfo>, name: String): String {
    for (f in fields) {
        if (f.name == name) { return f.typeName }
    }
    ""
}

func getDeclFieldType(cd: ClassDecl, name: String): String {
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                if (vd.identifier.value == name) { return vd.declType.toTokens().toString() }
            case _ => ()
        }
    }
    ""
}