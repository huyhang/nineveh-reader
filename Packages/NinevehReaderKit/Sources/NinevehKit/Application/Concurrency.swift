import Foundation

/// The result of `work`, or `nil` if it takes longer than `seconds`. For
/// lookups that improve what is shown but must not hold it up.
func firstResult<Value: Sendable>(
  within seconds: Double,
  _ work: @escaping @Sendable () async -> Value?
) async -> Value? {
  await withTaskGroup(of: Value?.self) { group in
    group.addTask { await work() }
    group.addTask {
      try? await Task.sleep(for: .seconds(seconds))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}

/// `fetch` for every id, at most `limit` at a time. Ids whose fetch returns
/// `nil` are left out.
func gather<Value: Sendable>(
  _ ids: [String],
  limit: Int,
  _ fetch: @escaping @Sendable (String) async -> Value?
) async -> [String: Value] {
  await withTaskGroup(of: (String, Value?).self) { group in
    var pending = ids[...]
    for _ in 0..<limit {
      guard let id = pending.popFirst() else { break }
      group.addTask { (id, await fetch(id)) }
    }
    var results: [String: Value] = [:]
    while let (id, value) = await group.next() {
      if let value { results[id] = value }
      if Task.isCancelled { continue }
      if let next = pending.popFirst() {
        group.addTask { (next, await fetch(next)) }
      }
    }
    return results
  }
}
