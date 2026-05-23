package refine

public enum StorageType {
    | Integer | Float | Decimal | `Bool`
    | String | Text | Json | Bytes | Timestamp
}

extend StorageType <: Equatable<StorageType> {
    public operator func ==(other: StorageType): Bool {
        match (this) {
            case Integer => match (other) { case Integer => true; case _ => false }
            case Float => match (other) { case Float => true; case _ => false }
            case Decimal => match (other) { case Decimal => true; case _ => false }
            case `Bool` => match (other) { case `Bool` => true; case _ => false }
            case String => match (other) { case String => true; case _ => false }
            case Text => match (other) { case Text => true; case _ => false }
            case Json => match (other) { case Json => true; case _ => false }
            case Bytes => match (other) { case Bytes => true; case _ => false }
            case Timestamp => match (other) { case Timestamp => true; case _ => false }
        }
    }
}

public interface TypeAdapter<T> {
    func storageType(): StorageType
    func toStored(value: T): Any
    func fromStored(stored: Any): T
}
