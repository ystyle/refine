macro package refine.macros

import std.ast.*
import std.collection.ArrayList

public macro Ref(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var target = ""
    var fk = fieldName + "_id"
    var via = ""
    var fieldsStr = ""

    if (attr.size >= 4 && attr[2].kind == TokenKind.IDENTIFIER) {
        // Check if first token is a positional target or a named arg keyword
        if (attr[0].kind == TokenKind.IDENTIFIER && attr[0].value != "target" && attr[0].value != "by" && attr[0].value != "via" && attr[0].value != "fields") {
            target = attr[0].value
        }
        for (i in 0..attr.size) {
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "target" && i + 2 < attr.size) { target = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "by" && i + 2 < attr.size) { fk = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "via" && i + 2 < attr.size) { via = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "fields" && i + 2 < attr.size) {
                var fieldsValues = ArrayList<String>()
                var j = i + 2
                if (j < attr.size && attr[j].kind == TokenKind.LSQUARE) {
                    j++
                    while (j < attr.size && attr[j].kind != TokenKind.RSQUARE) {
                        if (attr[j].kind == TokenKind.STRING_LITERAL) {
                            fieldsValues.add(attr[j].value)
                        }
                        j++
                    }
                }
                var firstField = true
                for (fv in fieldsValues) {
                    if (firstField) { fieldsStr = fv; firstField = false }
                    else { fieldsStr = fieldsStr + "|" + fv }
                }
            }
        }
    } else {
        var parsingTarget = true
        for (t in attr) {
            if (t.kind == TokenKind.IDENTIFIER) {
                if (t.value == "via") { via = t.value }
                else if (parsingTarget) { target = t.value; parsingTarget = false }
                else if (via == "") { fk = t.value }
            }
        }
    }
    if (target != "") {
        setItem("fieldName", fieldName)
        if (via != "") {
            setItem("kind", "ref_many")
            setItem("target", target); setItem("via", via)
        } else {
            setItem("kind", "ref_to")
            setItem("target", target); setItem("fk", fk)
        }
        if (fieldsStr != "") { setItem("fields", fieldsStr) }
    }
    input
}

public macro Rel(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var target = ""; var viaOrBy = ""; var fieldsStr = ""

    if (attr.size >= 4 && attr[2].kind == TokenKind.IDENTIFIER) {
        if (attr[0].kind == TokenKind.IDENTIFIER && (attr[0].value == "has_one" || attr[0].value == "has_many")) {
            // Legacy format: @Rel[has_many, Target, fk]
            for (t in attr) {
                if (t.kind == TokenKind.IDENTIFIER) {
                    if (t.value != "has_one" && t.value != "has_many") {
                        if (target == "") { target = t.value }
                        else if (viaOrBy == "") { viaOrBy = t.value }
                    }
                }
            }
        } else if (attr[0].kind == TokenKind.IDENTIFIER && attr[0].value != "target" && attr[0].value != "by" && attr[0].value != "fields") {
            target = attr[0].value
        }
        for (i in 0..attr.size) {
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "target" && i + 2 < attr.size) { target = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "by" && i + 2 < attr.size) { viaOrBy = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "fields" && i + 2 < attr.size) {
                var fieldsValues = ArrayList<String>()
                var j = i + 2
                if (j < attr.size && attr[j].kind == TokenKind.LSQUARE) {
                    j++
                    while (j < attr.size && attr[j].kind != TokenKind.RSQUARE) {
                        if (attr[j].kind == TokenKind.STRING_LITERAL) {
                            fieldsValues.add(attr[j].value)
                        }
                        j++
                    }
                }
                var firstField = true
                for (fv in fieldsValues) {
                    if (firstField) { fieldsStr = fv; firstField = false }
                    else { fieldsStr = fieldsStr + "|" + fv }
                }
            }
        }
    } else {
        var index = 0
        for (t in attr) {
            if (t.kind == TokenKind.IDENTIFIER) {
                if (t.value == "has_one" || t.value == "has_many") { continue }
                match (index) { case 0 => target = t.value; case 1 => viaOrBy = t.value; case _ => () }
                index++
            }
        }
    }
    if (target != "") {
        // Auto-detect kind from field type
        let inputStr = input.toString()
        let kind = if (inputStr.contains("ArrayList") || inputStr.contains("Array")) { "has_many" } else { "has_one" }
        setItem("fieldName", fieldName); setItem("kind", kind); setItem("target", target)
        if (viaOrBy != "") { setItem("via", viaOrBy) }
        if (fieldsStr != "") { setItem("fields", fieldsStr) }
    }
    input
}

public macro Field(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var storageType = "Text"
    for (i in 0..attr.size) {
        if (attr[i].kind == TokenKind.IDENTIFIER) { storageType = attr[i].value; break }
    }
    setItem("fieldName", fieldName); setItem("storageType", storageType)
    input
}

public macro Id(attr: Tokens, input: Tokens): Tokens {
    let decl = parseDecl(input)
    setItem("fieldName", decl.identifier.value)
    if (attr.size >= 3) {
        setItem("auto", attr[2].value)
    }
    input
}

public macro Table(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    for (i in 0..attr.size) {
        if (attr[i].kind == TokenKind.STRING_LITERAL) { setItem("name", attr[i].value); return input }
    }
    input
}

// Marker annotation: entity with this annotation uses physical delete instead of soft delete
public macro HardDelete(input: Tokens): Tokens { input }

public macro Version(input: Tokens): Tokens {
    let decl = parseDecl(input)
    setItem("fieldName", decl.identifier.value)
    input
}
