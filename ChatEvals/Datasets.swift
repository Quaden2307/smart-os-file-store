/// Every labelled sample, in the order they run: a hostile sample's twin always runs before it,
/// and the held-out set runs last.
enum Datasets {
    static let all: [ChatSample] = Requests.all + CannotDo.all + Hostile.all + HeldOut.all
}
