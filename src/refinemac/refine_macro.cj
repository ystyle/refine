macro package refine.refinemac

import std.ast.*
import std.collection.ArrayList

// --- Helper functions ---

func strStartsWith(s: String, prefix: String): Bool {
    if (s.size < prefix.size) { return false }
    s[0..prefix.size] == prefix
}

func strEndsWith(s: String, suffix: String): Bool {
    if (s.size < suffix.size) { return false }
    s[s.size - suffix.size..s.size] == suffix
}

// --- Data structures ---

struct FieldInfo {
    var name: String
    var typeName: String
    public init(name: String, typeName: String) {
        this.name = name
        this.typeName = typeName
    }
}

struct RelInfo {
    var fieldName: String
    var kind: String
    var target: String
    var by: String
    var fields: ArrayList<String>
    var via: String
    public init(fieldName: String, kind: String, target: String,
                by: String, fields: ArrayList<String>, via: String) {
        this.fieldName = fieldName
        this.kind = kind
        this.target = target
        this.by = by
        this.fields = fields
        this.via = via
    }
}

// --- Field Extraction ---

func extractFields(cd: ClassDecl): ArrayList<FieldInfo> {
    let list = ArrayList<FieldInfo>()
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let typeStr = vd.declType.toTokens().toString()
                let info = FieldInfo(vd.identifier.value, typeStr)
                list.add(info)
            case _ => ()
        }
    }
    list
}

// --- Relation Detection ---

func detectRelations(fields: ArrayList<FieldInfo>): ArrayList<RelInfo> {
    let result = ArrayList<RelInfo>()
    for (f in fields) {
        let tn = f.typeName
        let sz = tn.size
        if (strStartsWith(tn, "Option<") && strEndsWith(tn, ">") && sz > 8) {
            let targetType = tn[7..sz - 1]
            let byCol = f.name + "_id"
            let relFields = ArrayList<String>()
            relFields.add("id")
            let info = RelInfo(f.name, "ref_to", targetType, byCol, relFields, "")
            result.add(info)
        } else if (strStartsWith(tn, "ArrayList<") && strEndsWith(tn, ">") && sz > 11) {
            let targetType = tn[10..sz - 1]
            let relFields = ArrayList<String>()
            relFields.add("id")
            let info = RelInfo(f.name, "ref_many", targetType, "", relFields, f.name)
            result.add(info)
        } else if (strStartsWith(tn, "Array<") && strEndsWith(tn, ">") && sz > 7) {
            let targetType = tn[6..sz - 1]
            let relFields = ArrayList<String>()
            relFields.add("id")
            let info = RelInfo(f.name, "ref_many", targetType, "", relFields, f.name)
            result.add(info)
        }
    }
    result
}

func isFieldAnnotated(fieldName: String, refMessages: ArrayList<MacroMessage>, relMessages: ArrayList<MacroMessage>): Bool {
    for (m in refMessages) {
        if (m.getString("fieldName") == fieldName) {
            return true
        }
    }
    for (m in relMessages) {
        if (m.getString("fieldName") == fieldName) {
            return true
        }
    }
    false
}

func mergeAnnotationRels(rels: ArrayList<RelInfo>, refMessages: ArrayList<MacroMessage>, relMessages: ArrayList<MacroMessage>): ArrayList<RelInfo> {
    let result = ArrayList<RelInfo>()
    // Keep auto-detected rels for non-annotated fields only
    for (r in rels) {
        if (!isFieldAnnotated(r.fieldName, refMessages, relMessages)) {
            result.add(r)
        }
    }
    // Add @Ref messages
    for (m in refMessages) {
        let fieldName = m.getString("fieldName")
        let target = m.getString("target")
        let fk = m.getString("fk")
        let relFields = ArrayList<String>()
        relFields.add("id")
        result.add(RelInfo(fieldName, "ref_to", target, fk, relFields, ""))
    }
    // Add @Rel messages
    for (m in relMessages) {
        let fieldName = m.getString("fieldName")
        let kind = m.getString("kind")
        let target = m.getString("target")
        var via = ""
        if (m.hasItem("via")) {
            via = m.getString("via")
        }
        let relFields = ArrayList<String>()
        relFields.add("id")
        result.add(RelInfo(fieldName, kind, target, "", relFields, via))
    }
    result
}

// --- Code Generation ---

func buildColsStruct(className: String, cd: ClassDecl): Tokens {
    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    var colsFields = Tokens()
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                if (!first) {
                    colsFields = colsFields + Token(TokenKind.NL)
                }
                let fn = vd.identifier.value
                colsFields = colsFields + quote(
                    let $(vd.identifier): Col<$(vd.declType)> = Col<$(vd.declType)>($(Token(TokenKind.STRING_LITERAL, fn)))
                )
                first = false
            case _ => ()
        }
    }
    quote(
        struct $(colsName) {
            $(colsFields)
            init() {}
        }
    )
}

func buildRelClass(className: String, rels: ArrayList<RelInfo>): Tokens {
    let relClassName = Token(TokenKind.IDENTIFIER, className + "Rel")
    if (rels.size == 0) {
        return quote(class $(relClassName) {})
    }
    var body = Tokens()
    var first = true
    for (i in 0..rels.size) {
        let r = rels[i]
        if (!first) {
            body = body + Token(TokenKind.NL)
        }
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        let targetType = Token(TokenKind.IDENTIFIER, r.target)
        let nameLit = Token(TokenKind.STRING_LITERAL, r.fieldName)
        if (r.kind == "ref_to" || r.kind == "has_one") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            let idLit = Token(TokenKind.STRING_LITERAL, "id")
            body = body + quote(
                static let $(fieldIdent) = RefTo<$(targetType)>(
                    $(nameLit), Col<Any>($(fkLit)), [Col<Any>($(idLit))]
                )
            )
        } else {
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            let idLit = Token(TokenKind.STRING_LITERAL, "id")
            body = body + quote(
                static let $(fieldIdent) = RefMany<$(targetType)>(
                    $(nameLit), $(viaLit), [Col<Any>($(idLit))]
                )
            )
        }
        first = false
    }
    quote(
        class $(relClassName) {
            $(body)
        }
    )
}

func buildSaveMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func save(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), BeforeSave, scope)
            if (scope.aborted) {
                throw scope.error.getOrThrow()
            }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), AfterSave, afterScope)
        }
    )
}

func buildUpdateMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func update(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), BeforeUpdate, scope)
            if (scope.aborted) {
                throw scope.error.getOrThrow()
            }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), AfterUpdate, afterScope)
        }
    )
}

func buildDeleteMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func delete(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), BeforeDelete, scope)
            if (scope.aborted) {
                throw scope.error.getOrThrow()
            }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), AfterDelete, afterScope)
        }
    )
}

// --- Main Macro ---

public macro Refine(input: Tokens): Tokens {
    let classDecl = ClassDecl(input)
    let className = classDecl.identifier.value
    let classNameToken = classDecl.identifier

    let fields = extractFields(classDecl)
    let rels = detectRelations(fields)

    // Merge @Ref and @Rel child macro messages
    let refMessages = getChildMessages("Ref")
    let relMessages = getChildMessages("Rel")
    let mergedRels = mergeAnnotationRels(rels, refMessages, relMessages)

    let queryTokens = quote(
        static func query(): Query<$(classNameToken)> {
            Query<$(classNameToken)>()
        }
    )
    classDecl.body.decls.add(FuncDecl(queryTokens))

    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    let colTokens = quote(
        static func col(): $(colsName) {
            $(colsName)()
        }
    )
    classDecl.body.decls.add(FuncDecl(colTokens))

    let saveTokens = buildSaveMethod(className)
    classDecl.body.decls.add(FuncDecl(saveTokens))

    let updateTokens = buildUpdateMethod(className)
    classDecl.body.decls.add(FuncDecl(updateTokens))

    let deleteTokens = buildDeleteMethod(className)
    classDecl.body.decls.add(FuncDecl(deleteTokens))

    let colsStruct = buildColsStruct(className, classDecl)
    let relClass = buildRelClass(className, mergedRels)

    classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
        colsStruct + Token(TokenKind.NL) + Token(TokenKind.NL) + relClass
}

// --- @Ref and @Rel Attribute Macros ---

public macro Ref(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) {
        return input
    }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var target = ""
    var fk = fieldName + "_id"
    var parsingTarget = true
    for (t in attr) {
        if (t.kind == TokenKind.IDENTIFIER) {
            if (parsingTarget) {
                target = t.value
                parsingTarget = false
            } else {
                fk = t.value
            }
        }
    }
    if (target != "") {
        setItem("fieldName", fieldName)
        setItem("kind", "ref_to")
        setItem("target", target)
        setItem("fk", fk)
    }
    input
}

public macro Rel(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) {
        return input
    }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var kind = ""
    var target = ""
    var via = ""
    var index = 0
    for (t in attr) {
        if (t.kind == TokenKind.IDENTIFIER) {
            match (index) {
                case 0 => kind = t.value
                case 1 => target = t.value
                case 2 => via = t.value
                case _ => ()
            }
            index++
        }
    }
    if (kind != "" && target != "") {
        setItem("fieldName", fieldName)
        setItem("kind", kind)
        setItem("target", target)
        if (via != "") {
            setItem("via", via)
        }
    }
    input
}
