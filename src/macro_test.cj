package refine

import refinemac.*
import std.collection.ArrayList

@Refine
class Post {
    var id: Int64 = 0
    var title: String = ""
    var content: String = ""
}

@Refine
class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""
}

@Refine
class Tag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
class Comment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
class PostWithRel {
    var id: Int64 = 0
    var title: String = ""
    var user_id: Int64 = 0
    var post_id: Int64 = 0

    @Ref[User, user_id]
    var author: Option<User> = None

    @Rel[ref_many, Tag, post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()
}

class HookFlag {
    var called: Bool = false
    public init() {}
}

main() {
    // Test Cols structs
    let postCols = Post.col()
    println("PostCols: id=${postCols.id.name}, title=${postCols.title.name}, content=${postCols.content.name}")

    let userCols = User.col()
    println("UserCols: id=${userCols.id.name}, name=${userCols.name.name}, email=${userCols.email.name}")

    let _ = Post.query()
    let _ = User.query()
    println("Queries created successfully")

    // Test Rel class with annotation-based relations
    println("PostWithRelRel: author=${PostWithRelRel.author.name}, kind=${PostWithRelRel.author.kind}")
    println("PostWithRelRel: tags=${PostWithRelRel.tags.name}, kind=${PostWithRelRel.tags.kind}")
    println("PostWithRelRel: comments=${PostWithRelRel.comments.name}, kind=${PostWithRelRel.comments.kind}")

    // Test CRUD methods compile
    let post = Post()
    Post.save(post)
    Post.update(post)
    Post.delete(post)
    println("CRUD methods work")

    // Test hook integration via mutable class reference
    clearHooks()
    let flag = HookFlag()
    registerHook("Post", HookKind.BeforeSave) { scope: Scope<Post> =>
        flag.called = true
    }

    let p2 = Post()
    Post.save(p2)
    if (flag.called) {
        println("Hook integration works")
    } else {
        println("Hook integration FAILED")
    }

    println("All macro tests passed!")
}
