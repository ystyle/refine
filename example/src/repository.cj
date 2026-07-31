package demo

import refine.*

struct UserFind {
    var id: Option<Int64> = None
    var email: Option<String> = None
    var nameLike: Option<String> = None
    var withPosts: Bool = false
    var withProfile: Bool = false
    var orderBy: Option<String> = None
    var asc: Bool = true
    var limit: Option<Int64> = None
    var offset: Int64 = 0
    init() {}
}

struct PostFind {
    var id: Option<Int64> = None
    var userId: Option<Int64> = None
    var keyword: Option<String> = None
    var withAuthor: Bool = false
    var withComments: Bool = false
    var withTags: Bool = false
    var orderBy: Option<String> = None
    var asc: Bool = true
    var limit: Option<Int64> = None
    var offset: Int64 = 0
    init() {}
}

// ─── Repository 层 ──────────────────────────────────────

class UserRepo {

    static func save(tx: Tx, entity: User): Unit { tx.save(entity) }
    static func update(tx: Tx, entity: User): Unit { tx.update(entity) }
    static func delete(tx: Tx, entity: User): Unit { tx.delete(entity) }

    static func find(rf: Refine, p: UserFind): Array<User> {
        var q = User.query().using(rf)
        match (p.id) { case Some(v) => q = q.filter(User.col().id == v); case None => () }
        match (p.email) { case Some(v) => q = q.filter(User.col().email == v); case None => () }
        match (p.nameLike) {
            case Some(v) => q = q.filter(User.col().name.like("%" + v + "%"))
            case None => ()
        }
        if (p.withPosts) { q = q.include(UserRel.posts) }
        if (p.withProfile) { q = q.include(UserRel.profile) }
        match (p.limit) { case Some(v) => q = q.limit(v).offset(p.offset); case None => () }
        if (p.orderBy.isSome()) {
            let dir = if (p.asc) { User.col().id.asc() } else { User.col().id.desc() }
            q = q.order([dir])
        }
        q.all()
    }

    static func findOne(rf: Refine, p: UserFind): Option<User> {
        var q = User.query().using(rf)
        match (p.id) { case Some(v) => q = q.filter(User.col().id == v); case None => () }
        match (p.email) { case Some(v) => q = q.filter(User.col().email == v); case None => () }
        match (p.nameLike) {
            case Some(v) => q = q.filter(User.col().name.like("%" + v + "%"))
            case None => ()
        }
        if (p.withPosts) { q = q.include(UserRel.posts) }
        if (p.withProfile) { q = q.include(UserRel.profile) }
        q.one()
    }

    static func countAll(rf: Refine): Int64 { User.query().using(rf).count() }
}

class PostRepo {

    static func save(tx: Tx, entity: Post): Unit { tx.save(entity) }
    static func update(tx: Tx, entity: Post): Unit { tx.update(entity) }
    static func delete(tx: Tx, entity: Post): Unit { tx.delete(entity) }

    static func find(rf: Refine, p: PostFind): Array<Post> {
        var q = Post.query().using(rf)
        match (p.id) { case Some(v) => q = q.filter(Post.col().id == v); case None => () }
        match (p.userId) { case Some(v) => q = q.filter(Post.col().user_id == v); case None => () }
        match (p.keyword) {
            case Some(v) =>
                let titleMatch = Post.col().title.like("%" + v + "%")
                let bodyMatch = Post.col().body.like("%" + v + "%")
                q = q.filter(titleMatch.or(bodyMatch))
            case None => ()
        }
        if (p.withAuthor) { q = q.include(PostRel.author) }
        if (p.withComments) { q = q.include(PostRel.comments) }
        if (p.withTags) { q = q.include(PostRel.tags) }
        match (p.limit) { case Some(v) => q = q.limit(v).offset(p.offset); case None => () }
        if (p.orderBy.isSome()) {
            let dir = if (p.asc) { Post.col().id.desc() } else { Post.col().id.asc() }
            q = q.order([dir])
        }
        q.all()
    }

    static func findOne(rf: Refine, p: PostFind): Option<Post> {
        var q = Post.query().using(rf)
        match (p.id) { case Some(v) => q = q.filter(Post.col().id == v); case None => () }
        match (p.keyword) {
            case Some(v) =>
                let titleMatch = Post.col().title.like("%" + v + "%")
                let bodyMatch = Post.col().body.like("%" + v + "%")
                q = q.filter(titleMatch.or(bodyMatch))
            case None => ()
        }
        if (p.withAuthor) { q = q.include(PostRel.author) }
        if (p.withComments) { q = q.include(PostRel.comments) }
        if (p.withTags) { q = q.include(PostRel.tags) }
        q.one()
    }

    static func countAll(rf: Refine): Int64 { Post.query().using(rf).count() }
    static func existsById(rf: Refine, id: Int64): Bool {
        Post.query().using(rf).filter(Post.col().id == id).exists()
    }
}

class ProfileRepo {
    static func save(tx: Tx, entity: Profile): Unit { tx.save(entity) }
    static func findByUserId(rf: Refine, userId: Int64): Option<Profile> {
        Profile.query().using(rf).filter(Profile.col().user_id == userId).one()
    }
}

class CommentRepo {
    static func save(tx: Tx, entity: Comment): Unit { tx.save(entity) }
}

class TagRepo {
    static func save(tx: Tx, entity: Tag): Unit { tx.save(entity) }
    static func findByName(rf: Refine, name: String): Option<Tag> {
        Tag.query().using(rf).filter(Tag.col().name == name).one()
    }
}

struct EventFind {
    var id: Option<String> = None
    var name: Option<String> = None
    init() {}
}

class EventRepo {
    static func save(tx: Tx, entity: Event): Unit { tx.save(entity) }
    static func update(tx: Tx, entity: Event): Unit { tx.update(entity) }
    static func delete(tx: Tx, entity: Event): Unit { tx.delete(entity) }

    static func find(rf: Refine, p: EventFind): Array<Event> {
        var q = Event.query().using(rf)
        match (p.id) { case Some(v) => q = q.filter(Event.col().id == v); case None => () }
        match (p.name) { case Some(v) => q = q.filter(Event.col().name == v); case None => () }
        q.all()
    }

    static func findOne(rf: Refine, p: EventFind): Option<Event> {
        var q = Event.query().using(rf)
        match (p.id) { case Some(v) => q = q.filter(Event.col().id == v); case None => () }
        q.one()
    }
}
