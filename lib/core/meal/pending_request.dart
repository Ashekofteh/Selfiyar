/// The requests the platform made that the Dart side has not answered yet.
///
/// ## Why the platform records requests at all
///
/// The platform can ask the Dart side to do things at moments when there is
/// no Dart side to ask:
///
///   * a **hunt** wake-up, fired by an alarm, with the app killed;
///   * a **reboot**, fired by `BootReceiver` — and at boot the process is by
///     definition dead, so this one could never reach a live channel even in
///     principle.
///
/// Both used to be delivered through the method channel, whose other end only
/// exists while the activity is alive. So the native side **records** them and
/// the Dart side picks them up when it next runs. This file is the Dart half
/// of that vocabulary.
///
/// ## The format
///
/// An entry is `kind` or `kind:payload` — the kind names the request, and the
/// payload carries what the request needs. A hunt carries the account it is
/// for; a re-arm carries nothing.
library;

/// The kinds of request the platform can make.
enum PendingRequestKind {
  /// A hunt should be started.
  hunt,

  /// The reminder alarms should be re-armed.
  rearm,
}

/// One recorded request.
class PendingRequest {
  const PendingRequest(this.kind, [this.payload]);

  /// A hunt for [accountId].
  factory PendingRequest.hunt(String accountId) =>
      PendingRequest(PendingRequestKind.hunt, accountId);

  /// A re-arm of the reminder alarms.
  static const PendingRequest rearm =
      PendingRequest(PendingRequestKind.rearm);

  /// The separator between the kind and the payload.
  static const String separator = ':';

  /// What the request asks for.
  final PendingRequestKind kind;

  /// The account the request is about, for a hunt. Null for a re-arm.
  final String? payload;

  /// The entry, as the platform stores it.
  String get entry => payload == null
      ? kind.name
      : '${kind.name}$separator$payload';

  /// Reads an entry back, or null when it is not one of ours.
  ///
  /// Null rather than a guess: an entry the app does not recognise is
  /// somebody else's, and acting on it would be worse than ignoring it.
  static PendingRequest? parse(String entry) {
    final split = entry.indexOf(separator);
    final kindName = split < 0 ? entry : entry.substring(0, split);
    final payload = split < 0 ? null : entry.substring(split + 1);

    final kind = PendingRequestKind.values
        .where((k) => k.name == kindName)
        .cast<PendingRequestKind?>()
        .firstWhere((_) => true, orElse: () => null);
    if (kind == null) return null;

    if (kind == PendingRequestKind.hunt) {
      // A hunt with no account cannot be started — the configuration belongs
      // to an account — so the entry is not one of ours.
      if (payload == null || payload.isEmpty) return null;
      return PendingRequest.hunt(payload);
    }

    return PendingRequest.rearm;
  }

  @override
  String toString() => entry;

  @override
  bool operator ==(Object other) =>
      other is PendingRequest &&
      other.kind == kind &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(kind, payload);
}
