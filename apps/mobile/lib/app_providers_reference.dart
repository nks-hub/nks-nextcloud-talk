part of 'app_providers.dart';

typedef ReferenceUriLauncher = Future<bool> Function(Uri uri);

final referenceResolverProvider = Provider<ReferenceResolver>((ref) {
  final client = ref.watch(certificateTrustGateProvider).createClient();
  final resolver = HttpReferenceResolver(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    client: client,
  );
  ref.onDispose(resolver.close);
  return resolver;
});

final referenceUriLauncherProvider = Provider<ReferenceUriLauncher>((ref) {
  return (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
});

final referenceCardProvider = FutureProvider.autoDispose
    .family<ReferenceCardData?, ReferenceResolutionTarget>((ref, target) {
      final abort = Completer<void>();
      ref.onDispose(() {
        if (!abort.isCompleted) {
          abort.complete();
        }
      });
      return ref
          .watch(referenceResolverProvider)
          .resolve(target, abortTrigger: abort.future);
    });
