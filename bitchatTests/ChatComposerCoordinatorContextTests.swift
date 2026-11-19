//
// ChatComposerCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatComposerCoordinator` against a mock `ChatComposerContext` —
// proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` exemplar.
//
// Scope note: mention parsing uses the shared, precompiled
// `ChatViewModel.Patterns.mention` regex (a static, stateless singleton);
// everything else flows through the mock context.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatComposerContext` proving that
/// `ChatComposerCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatComposerContext: ChatComposerContext {
    // Autocomplete UI state
    var autocompleteSuggestions: [String] = []
    var autocompleteRange: NSRange?
    var showAutocomplete = false
    var selectedAutocompleteIndex = -1
    var queryResult: (suggestions: [String], range: NSRange?) = ([], nil)
    private(set) var queriedPeerCandidates: [[String]] = []
    private(set) var appliedSuggestions: [(suggestion: String, text: String, range: NSRange)] = []

    func autocompleteQuery(
        for text: String,
        peers: [String],
        cursorPosition: Int
    ) -> (suggestions: [String], range: NSRange?) {
        queriedPeerCandidates.append(peers.sorted())
        return queryResult
    }

    func applyAutocompleteSuggestion(_ suggestion: String, to text: String, range: NSRange) -> String {
        appliedSuggestions.append((suggestion, text, range))
        guard let textRange = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: textRange, with: suggestion)
    }

    // Identity & channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var meshNickname = "me"
    var meshNicknamesByPeerID: [PeerID: String] = [:]
    var blockedMeshNicknames: Set<String> = []
    var blockedNostrPubkeys: Set<String> = []

    func meshPeerNicknames() -> [PeerID: String] { meshNicknamesByPeerID }

    func isMeshNicknameBlocked(_ nickname: String) -> Bool {
        blockedMeshNicknames.contains(nickname)
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased.lowercased())
    }

    // Geohash identity
    var geoNicknames: [String: String] = [:]
    static let dummyIdentity = NostrIdentity(
        privateKey: Data(repeating: 0x11, count: 32),
        publicKey: Data(repeating: 0x22, count: 32),
        npub: "npub1mock",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        Self.dummyIdentity
    }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatComposerCoordinator` against `MockChatComposerContext` with
/// no `ChatViewModel`.
struct ChatComposerCoordinatorContextTests {

    @Test @MainActor
    func updateAutocomplete_onMesh_excludesOwnNicknameAndPublishesSuggestions() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [
            PeerID(str: "1111111111111111"): "alice",
            PeerID(str: "2222222222222222"): "bob",
            PeerID(str: "3333333333333333"): "me"
        ]

        // Matching query: suggestions and range are published, index resets.
        context.queryResult = (["@alice"], NSRange(location: 0, length: 3))
        coordinator.updateAutocomplete(for: "@al", cursorPosition: 3)
        #expect(context.queriedPeerCandidates == [["alice", "bob"]])
        #expect(context.autocompleteSuggestions == ["@alice"])
        #expect(context.autocompleteRange == NSRange(location: 0, length: 3))
        #expect(context.showAutocomplete)
        #expect(context.selectedAutocompleteIndex == 0)

        // No match: all autocomplete state is cleared.
        context.queryResult = ([], nil)
        context.selectedAutocompleteIndex = 3
        coordinator.updateAutocomplete(for: "plain text", cursorPosition: 5)
        #expect(context.autocompleteSuggestions.isEmpty)
        #expect(context.autocompleteRange == nil)
        #expect(!context.showAutocomplete)
        #expect(context.selectedAutocompleteIndex == 0)
    }

    @Test @MainActor
    func updateAutocomplete_onLocationChannel_buildsGeoTokensWithoutOwnToken() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruydq"))
        context.geoNicknames = [
            "aaaabbbbccccdddd": "carol",
            // Own token (nickname#last-4-of-pubkey) must be removed; the dummy
            // identity's public key hex ends in "2222".
            "ffffeeeeddddcccc2222": "me"
        ]

        coordinator.updateAutocomplete(for: "@ca", cursorPosition: 3)
        #expect(context.queriedPeerCandidates == [["carol#dddd"]])
    }

    @Test @MainActor
    func updateAutocomplete_excludesBlockedMeshAndGeohashPeers() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [
            PeerID(str: "1111111111111111"): "alice",
            PeerID(str: "2222222222222222"): "eve",
            PeerID(str: "3333333333333333"): "me"
        ]
        context.blockedMeshNicknames = ["eve"]
        context.queryResult = (["@alice"], NSRange(location: 0, length: 3))

        coordinator.updateAutocomplete(for: "@a", cursorPosition: 2)
        #expect(context.queriedPeerCandidates == [["alice"]])

        let geoContext = MockChatComposerContext()
        let geoCoordinator = ChatComposerCoordinator(context: geoContext)
        geoContext.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruydq"))
        geoContext.geoNicknames = [
            "aaaabbbbccccdddd": "carol",
            "bbbbccccddddeeee": "blocked"
        ]
        geoContext.blockedNostrPubkeys = ["bbbbccccddddeeee"]

        geoCoordinator.updateAutocomplete(for: "@", cursorPosition: 1)
        #expect(geoContext.queriedPeerCandidates == [["carol#dddd"]])
    }

    @Test @MainActor
    func completeNickname_appliesSuggestionResetsStateAndReturnsCursor() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)

        // Without an active range the text is untouched.
        var text = "hello @al"
        #expect(coordinator.completeNickname("@alice", in: &text) == text.count)
        #expect(context.appliedSuggestions.isEmpty)

        // With a range the suggestion is applied and state cleared.
        context.autocompleteRange = NSRange(location: 6, length: 3)
        context.autocompleteSuggestions = ["@alice"]
        context.showAutocomplete = true
        let cursor = coordinator.completeNickname("@alice", in: &text)
        #expect(text == "hello @alice")
        #expect(cursor == 6 + "@alice".count + 1)
        #expect(!context.showAutocomplete)
        #expect(context.autocompleteSuggestions.isEmpty)
        #expect(context.autocompleteRange == nil)
        #expect(context.selectedAutocompleteIndex == 0)
    }

    @Test @MainActor
    func parseMentions_generatedQuoteDoesNotMentionKnownPeersOrSelf() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [
            PeerID(str: "1111111111111111"): "bob",
            PeerID(str: "2222222222222222"): "日本語"
        ]
        let content = "👋 hello @bob\n再会 @日本語 and @me#0011"
        #expect(Set(coordinator.parseMentions(from: content)) == ["bob", "日本語", "me#0011"])

        let draft = MessageClipboard.appendQuote(to: "", content: content, sender: "alice")
        #expect(coordinator.parseMentions(from: draft).isEmpty)
        // Public mesh and Nostr ingress trim content before re-parsing it.
        #expect(coordinator.parseMentions(from: draft.trimmed).isEmpty)
    }

    @Test @MainActor
    func parseMentions_quotePreservesDeliberateMentionsThroughPrivatePacket() throws {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [PeerID(str: "1111111111111111"): "bob"]
        let draft = MessageClipboard.appendQuote(
            to: "before @me",
            content: "hello @bob\n再会 @me#0011",
            sender: "alice"
        ) + "after @bob"
        #expect(Set(coordinator.parseMentions(from: draft)) == ["me", "bob"])

        // Noise DM ingress decodes the real packet and parses its content again.
        let payload = try #require(PrivateMessagePacket(messageID: "quote-regression", content: draft).encode())
        let received = try #require(PrivateMessagePacket.decode(from: payload))
        #expect(received.content == draft)
        context.nickname = "bob"
        context.meshNicknamesByPeerID = [PeerID(str: "0011223344556677"): "me"]
        #expect(Set(coordinator.parseMentions(from: received.content)) == ["me", "bob"])
    }

    @Test @MainActor
    func parseMentions_generatedQuoteAccountsForPrivatePacketUTF8Limit() throws {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [PeerID(str: "1111111111111111"): "bob"]

        for extraByteCount in 0...1 {
            let content = String(repeating: "x", count: extraByteCount) + String(repeating: "é", count: 118) + " @bob"
            // Match the composer's trimming before send. The old quote fits in both cases.
            let originalQuote = "> alice:\n> " + content
            let quoted = MessageClipboard.quoteForComposer(content, sender: "alice").trimmed
            #expect(originalQuote.utf8.count == 252 + extraByteCount)
            #expect(PrivateMessagePacket(messageID: "quote-budget", content: originalQuote).encode() != nil)
            #expect(coordinator.parseMentions(from: originalQuote) == ["bob"])
            // U+200B adds three bytes, not one, without changing the TLV limit.
            #expect(quoted.utf8.count == 255 + extraByteCount)
            #expect(coordinator.parseMentions(from: quoted).isEmpty)

            let packet = PrivateMessagePacket(messageID: "quote-budget", content: quoted)
            if extraByteCount == 0 {
                let payload = try #require(packet.encode())
                let received = try #require(PrivateMessagePacket.decode(from: payload))
                #expect(received.content == quoted)
                #expect(coordinator.parseMentions(from: received.content).isEmpty)
            } else {
                #expect(packet.encode() == nil)
            }
        }
    }

    @Test @MainActor
    func parseMentions_acceptsKnownPeersOwnNicknameAndHashSuffix() {
        let context = MockChatComposerContext()
        let coordinator = ChatComposerCoordinator(context: context)
        context.meshNicknamesByPeerID = [PeerID(str: "1111111111111111"): "alice"]

        let mentions = coordinator.parseMentions(
            from: "hi @alice and @me and @me#0011 but not @stranger"
        )
        #expect(Set(mentions) == ["alice", "me", "me#0011"])
    }
}
