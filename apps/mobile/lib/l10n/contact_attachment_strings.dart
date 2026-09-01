import 'generated/app_localizations.dart';

final class ContactAttachmentStrings {
  const ContactAttachmentStrings._({
    required this.permissionDenied,
    required this.pickerUnavailable,
    required this.invalidSelection,
  });

  factory ContactAttachmentStrings.from(AppLocalizations strings) {
    if (strings.localeName.split(RegExp('[-_]')).first == 'cs') {
      return const ContactAttachmentStrings._(
        permissionDenied: 'Přístup k vybranému kontaktu byl odepřen.',
        pickerUnavailable: 'Systémový výběr kontaktu není dostupný.',
        invalidSelection: 'Vybraný kontakt se nepodařilo připojit.',
      );
    }
    return const ContactAttachmentStrings._(
      permissionDenied: 'Access to the selected contact was denied.',
      pickerUnavailable: 'The system contact picker is unavailable.',
      invalidSelection: 'The selected contact could not be attached.',
    );
  }

  final String permissionDenied;
  final String pickerUnavailable;
  final String invalidSelection;
}
