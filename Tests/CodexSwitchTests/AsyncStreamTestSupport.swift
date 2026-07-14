import Foundation

func nextElement<Element: Sendable>(
    from stream: AsyncStream<Element>
) async -> Element? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}
