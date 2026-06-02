package demo

import refine.*

// ─── Service 层 ─────────────────────────────────────────
// 业务方法，不引用 ORM 内部类型

class UserService {

    static func register(rf: Refine, name: String, email: String): User {
        rf.transaction { tx: Tx =>
            let u = User()
            u.name = name
            u.email = email
            UserRepo.save(tx, u)
            u
        }
    }

    static func updateEmail(rf: Refine, id: Int64, newEmail: String): User {
        rf.transaction { tx: Tx =>
            var p = UserFind()
            p.id = Some(id)
            let u = UserRepo.findOne(rf, p).getOrThrow()
            u.email = newEmail
            UserRepo.update(tx, u)
            u
        }
    }

    static func getWithPosts(rf: Refine, id: Int64): Option<User> {
        var p = UserFind()
        p.id = Some(id)
        p.withPosts = true
        UserRepo.findOne(rf, p)
    }

    static func addPost(rf: Refine, userId: Int64, title: String, body: String): Post {
        rf.transaction { tx: Tx =>
            let p = Post()
            p.title = title
            p.body = body
            p.user_id = userId
            PostRepo.save(tx, p)
            p
        }
    }

    static func deleteUser(rf: Refine, id: Int64): Unit {
        rf.transaction { tx: Tx =>
            var p = UserFind()
            p.id = Some(id)
            let u = UserRepo.findOne(rf, p).getOrThrow()
            UserRepo.delete(tx, u)
        }
    }

    static func nestedRollback(rf: Refine, name: String): Unit {
        rf.transaction { tx: Tx =>
            let u = User()
            u.name = name
            u.email = name + "@t.com"
            UserRepo.save(tx, u)
            tx.save("before_rollback")
            let doomed = User()
            doomed.name = name + "_rollbacked"
            doomed.email = doomed.name + "@t.com"
            UserRepo.save(tx, doomed)
            tx.rollbackTo("before_rollback")
        }
    }
}

class PostService {

    static func create(rf: Refine, title: String, body: String, authorId: Int64): Post {
        rf.transaction { tx: Tx =>
            let p = Post()
            p.title = title
            p.body = body
            p.user_id = authorId
            PostRepo.save(tx, p)
            p
        }
    }

    static func getDetails(rf: Refine, id: Int64): Option<Post> {
        var p = PostFind()
        p.id = Some(id)
        p.withAuthor = true
        p.withComments = true
        p.withTags = true
        PostRepo.findOne(rf, p)
    }

    static func addComment(rf: Refine, postId: Int64, body: String): Comment {
        rf.transaction { tx: Tx =>
            let c = Comment()
            c.body = body
            c.post_id = postId
            CommentRepo.save(tx, c)
            c
        }
    }

    static func addTags(rf: Refine, postId: Int64, names: Array<String>): Unit {
        rf.transaction { tx: Tx =>
            for (name in names) {
                let tag = match (TagRepo.findByName(rf, name)) {
                    case Some(t) => t
                    case None =>
                        let t = Tag()
                        t.name = name
                        TagRepo.save(tx, t)
                        t
                }
                tx.execute("INSERT INTO post_tags (post_id, tag_id) VALUES (?, ?)", [postId, tag.id])
            }
        }
    }

    static func countAll(rf: Refine): Int64 { PostRepo.countAll(rf) }
    static func existsById(rf: Refine, id: Int64): Bool { PostRepo.existsById(rf, id) }
}

class ProfileService {
    static func setProfile(rf: Refine, userId: Int64, bio: String, avatar: String): Profile {
        rf.transaction { tx: Tx =>
            let p = Profile()
            p.bio = bio
            p.avatar = avatar
            p.user_id = userId
            ProfileRepo.save(tx, p)
            p
        }
    }
}
