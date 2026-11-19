import Foundation
import Testing
@testable import bitchat

struct MessageClipboardTests {
    @Test func quoteWrapsEachLineAndAddsSender() {
        let quoted = MessageClipboard.quoteForComposer("hello\nworld", sender: "alice")
        #expect(quoted == "> alice:\n> hello\n> world\n\n")
    }

    @Test func quoteNeutralizesMentionsRatherThanRelyingOnLinePrefixesOrBackslashes() {
        let content = "hello @bob and \\@carol"
        // These are literal characters, not Markdown/mention escaping.
        #expect(MessageFormattingEngine.extractMentions(from: "> " + content) == ["bob", "carol"])

        let quoted = MessageClipboard.quoteForComposer(content, sender: "alice")
        #expect(quoted == "> alice:\n> hello @\u{200B}bob and \\@\u{200B}carol\n\n")
        #expect(MessageFormattingEngine.extractMentions(from: quoted).isEmpty)
    }

    @Test func quoteNeutralizesMultilineUnicodeAndSuffixedMentions() {
        let content = "👋 @bob#a1b2\n\n再会 @日本語 and @émile\n> nested @dana"
        let quoted = MessageClipboard.quoteForComposer(content, sender: "alice")
        #expect(quoted == "> alice:\n> 👋 @\u{200B}bob#a1b2\n> \n> 再会 @\u{200B}日本語 and @\u{200B}émile\n> > nested @\u{200B}dana\n\n")
        #expect(MessageFormattingEngine.extractMentions(from: quoted).isEmpty)

        let requoted = MessageClipboard.quoteForComposer(quoted, sender: "carol")
        #expect(MessageFormattingEngine.extractMentions(from: requoted).isEmpty)
        #expect(!requoted.contains("@\u{200B}\u{200B}"))
    }

    @Test func quoteLeavesNonMentionAtSignsAndOtherTextUnchanged() {
        let content = "a lone @ and @🙂 https://example.com #mesh"
        let quoted = MessageClipboard.quoteForComposer(content, sender: nil)
        #expect(quoted == "> " + content + "\n\n")
    }

    @Test func quoteSkipsSystemSenderHeader() {
        let quoted = MessageClipboard.quoteForComposer("joined", sender: "system")
        #expect(quoted == "> joined\n\n")
    }

    @Test func emptyContentYieldsEmptyQuote() {
        #expect(MessageClipboard.quoteForComposer("   ", sender: "alice").isEmpty)
    }

    @Test func appendQuotePreservesExistingDraft() {
        let result = MessageClipboard.appendQuote(
            to: "already typing",
            content: "prior message",
            sender: "bob"
        )
        #expect(result == "already typing\n> bob:\n> prior message\n\n")
    }

    @Test func appendQuoteOntoEmptyDraft() {
        let result = MessageClipboard.appendQuote(
            to: "",
            content: "solo",
            sender: "carol"
        )
        #expect(result == "> carol:\n> solo\n\n")
    }

    @Test func appendQuoteAfterTrailingSpaceStartsNewLine() {
        let result = MessageClipboard.appendQuote(
            to: "draft with space ",
            content: "quoted",
            sender: "dana"
        )
        #expect(result == "draft with space \n> dana:\n> quoted\n\n")
    }
}
