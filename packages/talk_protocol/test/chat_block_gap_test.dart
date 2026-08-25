import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

/// `mergeChatBlocks` and `ChatScopeState` are the source of truth for whether
/// a chat scope's cached history has a gap in it. These tests pin that
/// contract directly, independent of the mobile UI that reads it: an
/// adjacent/overlapping pair of fetched ranges collapses into one block, but
/// two ranges with unfetched messages between them must stay two separate
/// blocks so a client can tell "contiguous history" from "two islands with a
/// hole in between".
void main() {
  group('mergeChatBlocks', () {
    test('merges overlapping blocks into one', () {
      final merged = mergeChatBlocks(<ChatBlock>[
        ChatBlock(start: _cursor(10), end: _cursor(50)),
        ChatBlock(start: _cursor(30), end: _cursor(80)),
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.start, _cursor(10));
      expect(merged.single.end, _cursor(80));
    });

    test('merges adjacent blocks (no digit gap) into one', () {
      final merged = mergeChatBlocks(<ChatBlock>[
        ChatBlock(start: _cursor(10), end: _cursor(50)),
        ChatBlock(start: _cursor(51), end: _cursor(80)),
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.start, _cursor(10));
      expect(merged.single.end, _cursor(80));
    });

    test('keeps two ranges separate when messages between them were '
        'never fetched', () {
      final merged = mergeChatBlocks(<ChatBlock>[
        ChatBlock(start: _cursor(60), end: _cursor(80)),
        ChatBlock(start: _cursor(10), end: _cursor(50)),
      ]);
      expect(merged, hasLength(2));
      expect(merged[0].start, _cursor(10));
      expect(merged[0].end, _cursor(50));
      expect(merged[1].start, _cursor(60));
      expect(merged[1].end, _cursor(80));
    });

    test('a later merge can still close a gap once the middle is fetched', () {
      final withGap = mergeChatBlocks(<ChatBlock>[
        ChatBlock(start: _cursor(10), end: _cursor(50)),
        ChatBlock(start: _cursor(60), end: _cursor(80)),
      ]);
      final closed = mergeChatBlocks(<ChatBlock>[
        ...withGap,
        ChatBlock(start: _cursor(50), end: _cursor(60)),
      ]);
      expect(closed, hasLength(1));
      expect(closed.single.start, _cursor(10));
      expect(closed.single.end, _cursor(80));
    });
  });

  group('ChatScopeState with a gap', () {
    test('accepts two disjoint blocks that span history to future cursor', () {
      final scope = ChatScopeState(
        messageIds: const <int>[15, 45, 65, 75],
        historyCursor: _cursor(10),
        futureCursor: _cursor(80),
        lastCommonRead: _cursor(10),
        lastReadMessage: 0,
        unreadMessages: 0,
        hasHistory: true,
        futureConverged: false,
        blocks: <ChatBlock>[
          ChatBlock(start: _cursor(10), end: _cursor(50)),
          ChatBlock(start: _cursor(60), end: _cursor(80)),
        ],
      );
      expect(scope.blocks, hasLength(2));
    });

    test('rejects a cached message id that falls inside the gap', () {
      expect(
        () => ChatScopeState(
          messageIds: const <int>[15, 55, 65],
          historyCursor: _cursor(10),
          futureCursor: _cursor(80),
          lastCommonRead: _cursor(10),
          lastReadMessage: 0,
          unreadMessages: 0,
          hasHistory: true,
          futureConverged: false,
          blocks: <ChatBlock>[
            ChatBlock(start: _cursor(10), end: _cursor(50)),
            ChatBlock(start: _cursor(60), end: _cursor(80)),
          ],
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });
  });
}

ChatCursor _cursor(int value) => ChatCursor.parse(value.toString());
