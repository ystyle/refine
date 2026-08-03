macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func buildPkValueExprTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    if (pkFields.size == 0) {
        Tokens() + Token(TokenKind.IDENTIFIER, "entity") + Token(TokenKind.DOT) + Token(TokenKind.IDENTIFIER, "id")
    } else if (pkFields.size == 1) {
        let pk = pkFields.get(0).getOrThrow()
        Tokens() + Token(TokenKind.IDENTIFIER, "entity") + Token(TokenKind.DOT) + Token(TokenKind.IDENTIFIER, pk.name)
    } else {
        var t = Tokens()
        var first = true
        for (pk in pkFields) {
            if (!first) {
                t = t + Token(TokenKind.ADD)
                t = t + Token(TokenKind.STRING_LITERAL, ":")
                t = t + Token(TokenKind.ADD)
            }
            t = t + Token(TokenKind.IDENTIFIER, "entity")
            t = t + Token(TokenKind.DOT)
            t = t + Token(TokenKind.IDENTIFIER, pk.name)
            t = t + Token(TokenKind.DOT)
            t = t + Token(TokenKind.IDENTIFIER, "toString")
            t = t + Token(TokenKind.LPAREN)
            t = t + Token(TokenKind.RPAREN)
            first = false
        }
        t
    }
}


func genFieldCols(fieldNames: ArrayList<String>): Tokens {
    var tokens = Tokens()
    tokens = tokens + Token(TokenKind.LSQUARE)
    var first = true
    for (name in fieldNames) {
        if (!first) { tokens = tokens + Token(TokenKind.COMMA) }
        let nameLit = Token(TokenKind.STRING_LITERAL, name)
        tokens = tokens + quote(Col<Any>($(nameLit)))
        first = false
    }
    tokens = tokens + Token(TokenKind.RSQUARE)
    tokens
}

func buildEntityArrayTokens(fields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, f.name)
        first = false
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}


func buildClientPkGenTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        let fName = Token(TokenKind.IDENTIFIER, pk.name)
        if (pk.typeName == "String") {
            body = body + quote(
                if (entity.$(fName) == "" && this.ref.isSome()) { entity.$(fName) = this.ref.getOrThrow().getIdGenerator().generate() }
            )
        } else if (pk.typeName == "Int64" && !pk.autoInc) {
            body = body + quote(
                if (entity.$(fName) == 0 && this.ref.isSome()) { entity.$(fName) = parseId64(this.ref.getOrThrow().getIdGenerator().generate()) }
            )
        }
    }
    body
}

func buildClientPkGenTokensBatch(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        let fName = Token(TokenKind.IDENTIFIER, pk.name)
        if (pk.typeName == "String") {
            body = body + quote(
                if (entities[_bi_].$(fName) == "" && this.ref.isSome()) { entities[_bi_].$(fName) = this.ref.getOrThrow().getIdGenerator().generate() }
            )
        } else if (pk.typeName == "Int64" && !pk.autoInc) {
            body = body + quote(
                if (entities[_bi_].$(fName) == 0 && this.ref.isSome()) { entities[_bi_].$(fName) = parseId64(this.ref.getOrThrow().getIdGenerator().generate()) }
            )
        }
    }
    body
}

func buildAutoPkAssignTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        if (pk.autoInc) {
            let fName = Token(TokenKind.IDENTIFIER, pk.name)
            body = body + quote(
                entity.$(fName) = result.lastInsertId;
            )
        }
    }
    body
}

func buildAutoPkReturningTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        if (pk.autoInc) {
            let fName = Token(TokenKind.IDENTIFIER, pk.name)
            body = body + quote(
                entity.$(fName) = qr.get<Int64>(0);
            )
        }
    }
    body
}

func genPkValueParamsTokens(pkFields: ArrayList<FieldInfo>, target: String): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        body = body + quote(
            allParams.add($(Token(TokenKind.IDENTIFIER, target)).$(Token(TokenKind.IDENTIFIER, pk.name)));
        )
    }
    body
}

func buildDeleteEntityParamsToken(pkFields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (pk in pkFields) {
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, pk.name)
        first = false
    }
    if (first) {  // fallback
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, "id")
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

// M9: 软删 SET deleted_at 的参数值按列类型生成——Int64 写整数 1（历史行为），
// DateTime 写 DateTime.now()（时间戳软删，配合 IS NULL 过滤）。
func buildSoftDeleteEntityParamsToken(pkFields: ArrayList<FieldInfo>, deletedAtIsDateTime: Bool): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    if (deletedAtIsDateTime) {
        arr = arr + quote(DateTime.now())
    } else {
        arr = arr + Token(TokenKind.IDENTIFIER, "1")
    }
    for (pk in pkFields) {
        arr = arr + Token(TokenKind.COMMA)
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, pk.name)
    }
    if (pkFields.size == 0) {
        arr = arr + Token(TokenKind.COMMA)
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, "id")
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildUpdateEntityArrayTokens(fields: ArrayList<FieldInfo>, pkFields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, f.name)
        first = false
    }
    for (i in 0..pkFields.size) {
        let pk = pkFields.get(i).getOrThrow()
        if (first) { first = false } else { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, pk.name)
    }
    let versionName = findVersionField(fields)
    if (versionName != "") {
        if (first) { first = false } else { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, versionName)
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}