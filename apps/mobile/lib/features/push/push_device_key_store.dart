/// Generates and stores this device's per-account RSA-2048 push key.
///
/// The private half never leaves the platform keystore — [ensureKey] only
/// ever returns the public key's PEM. A notification extension is the only
/// other thing on-device that ever touches the private key, to decrypt an
/// incoming push.
abstract interface class PushDeviceKeyStore {
  /// Returns the SubjectPublicKeyInfo PEM for [handle], generating a
  /// keystore-resident RSA-2048 keypair on first use and reusing it on every
  /// later call with the same handle.
  Future<String> ensureKey(String handle);

  /// Deletes the keystore-resident keypair for [handle], if any.
  Future<void> destroyKey(String handle);
}
