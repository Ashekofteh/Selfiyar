/// The portal adapter boundary.
///
/// Import this one path to get the contract and every type it speaks. The two
/// halves are split so the interface stays readable and so a caller that only
/// needs the shapes can import `portal_models.dart` alone; nothing here adds
/// logic of its own.
library;

export 'portal_client.dart';
export 'portal_models.dart';
