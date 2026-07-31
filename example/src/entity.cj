package demo

import std.collection.ArrayList
import std.collection.HashMap
import std.database.sql.QueryResult
import refine.*
import refine.macros.*

// ─── 实体 ───────────────────────────────────────────────

@Refine
public class User {
    var id: Int64 = 0
    var name: String = ""
    var email: String = ""

    @Rel[has_many, Post, user_id]
    var posts: ArrayList<Post> = ArrayList<Post>()

    @Rel[has_one, Profile, user_id]
    var profile: Option<Profile> = None
}

@Refine
public class Profile {
    var id: Int64 = 0
    var bio: String = ""
    var avatar: String = ""
    var user_id: Int64 = 0
}

@Refine
public class Post {
    var id: Int64 = 0
    var title: String = ""
    @Field[Text]
    var body: String = ""
    var user_id: Int64 = 0

    @Ref[User, user_id]
    var author: Option<User> = None

    @Rel[has_many, Comment, post_id]
    var comments: ArrayList<Comment> = ArrayList<Comment>()

    @Ref[Tag, via: post_tags]
    var tags: ArrayList<Tag> = ArrayList<Tag>()
}

@Refine
public class Comment {
    var id: Int64 = 0
    var body: String = ""
    var post_id: Int64 = 0
}

@Refine
public class Tag {
    var id: Int64 = 0
    var name: String = ""
}

@Refine
class Event {
    var id: String = ""
    var name: String = ""
    var payload: String = ""
}
