import FCheckCore
import Foundation
import SourceCorpus
import Testing

/// The callee of a call is read from its tokens, so analysing a chain of calls costs time proportional to its length. A
/// SwiftUI view is such a chain (`VStack { … }.padding().frame(…)…`): when the callee was the source text of the whole
/// called expression, each link re-read everything before it, and the cost grew with the square of the chain.
/// (Chains stay short here: far deeper ones overflow the stack in swift-syntax's location converter on a test thread,
/// which is analyzerkit roadmap 0041.)
@Suite struct CallSiteScalingTests {
    private static func chain(_ links: Int) -> String {
        "func f() {\n    let v = view" + String(repeating: ".modifier(1)", count: links) + "\n    print(v)\n}\n"
    }

    /// The fastest of three runs, so a busy machine slows a run without failing the test. The runs are on the large stack
    /// the tool gives its analysis: a sanitized debug build fills a test thread's stack with a chain this long.
    private static func seconds(_ source: String) async -> Double {
        await LargeStack.run {
            (0..<3).map { _ in
                let clock = ContinuousClock()
                let elapsed = clock.measure { _ = analyze(source) }
                return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            }.min() ?? 0
        }
    }

    @Test func `four times the chain costs about four times the time, not sixteen`() async {
        let short = await Self.seconds(Self.chain(50))
        let long = await Self.seconds(Self.chain(200))
        #expect(long / short < 8, "50 links: \(short) s, 200 links: \(long) s, ratio \(long / short)")
    }
}
