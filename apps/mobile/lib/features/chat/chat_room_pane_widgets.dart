part of 'chat_room_pane.dart';

final class ChatThreadScreen extends ConsumerWidget {
  const ChatThreadScreen({
    super.key,
    required this.account,
    required this.conversation,
    required this.threadContext,
    this.jumpToMessageId,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final ChatThreadContext threadContext;
  final int? jumpToMessageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadId = threadContext.rootMessageId;
    final key = (
      accountId: threadContext.accountId,
      roomToken: threadContext.roomToken,
      threadId: threadId,
    );
    final messages = ref.watch(chatMessagesProvider(key)).valueOrNull;
    final root = messages == null ? null : _findRoot(messages, threadId);
    final liveThreadContext = root == null
        ? null
        : ChatThreadContext.fromCachedRoot(
            accountId: threadContext.accountId,
            roomToken: threadContext.roomToken,
            root: root,
          );
    return Scaffold(
      key: Key('chat-thread-screen-$threadId'),
      appBar: AppBar(
        title: Text(
          liveThreadContext?.isNamed == true
              ? liveThreadContext!.title!
              : AppLocalizations.of(context).thread,
        ),
      ),
      body: SafeArea(
        top: false,
        child: ChatBackgroundSurface(
          accountId: account.id,
          roomToken: conversation.token,
          child: ChatRoomPane(
            account: account,
            conversation: conversation,
            threadId: threadId,
            threadContext: liveThreadContext,
            jumpToMessageId: jumpToMessageId,
          ),
        ),
      ),
    );
  }

  CachedChatMessage? _findRoot(List<CachedChatMessage> messages, int threadId) {
    for (final message in messages) {
      if (message.messageId == threadId) {
        return message;
      }
    }
    return null;
  }
}

final class ChatRoomPane extends ConsumerStatefulWidget {
  const ChatRoomPane({
    super.key,
    required this.account,
    required this.conversation,
    this.showHeader = false,
    this.threadId,
    this.threadContext,
    this.jumpToMessageId,
    this.incomingMessageAnnouncementController,
  }) : assert(threadId == null || threadId > 0),
       assert(threadContext == null || threadId != null),
       assert(jumpToMessageId == null || jumpToMessageId > 0);

  final StoredAccount account;
  final CachedConversation conversation;
  final bool showHeader;
  final int? threadId;
  final ChatThreadContext? threadContext;

  @visibleForTesting
  final IncomingMessageAnnouncementController?
  incomingMessageAnnouncementController;

  /// A message to reveal once the first synchronization settles, instead of
  /// opening at the newest message. Used by message search and by tapping a
  /// quoted original.
  final int? jumpToMessageId;

  @override
  ConsumerState<ChatRoomPane> createState() => _ChatRoomPaneState();
}
