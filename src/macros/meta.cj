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

func isRelationField(typeName: String): Bool {
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
    if (typeName == "Int8" || typeName == "Int16" || typeName == "Int32" || typeName == "Int64" ||
        typeName == "UInt8" || typeName == "UInt16" || typeName == "UInt32" || typeName == "UInt64") {
        "StorageType.Integer"
    } else if (typeName == "Float32" || typeName == "Float64") { "StorageType.Float"
    } else if (typeName == "Bool") { "StorageType.`Bool`"
    } else if (typeName == "String") { "StorageType.String"
    } else if (typeName == "Array<UInt8>") { "StorageType.Bytes"
    } else if (typeName == "DateTime") { "StorageType.Timestamp"
    } else { "StorageType.Json" }
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