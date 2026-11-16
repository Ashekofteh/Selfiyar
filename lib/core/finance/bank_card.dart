/// Models and utilities for saved bank cards used in top-up payments.
library;

/// Represents a bank payment card saved by the student for fast top-up.
class SavedBankCard {
  const SavedBankCard({
    required this.id,
    required this.pan,
    this.title,
    this.bankName,
    this.expMonth,
    this.expYear,
    this.cvv2,
    this.savedAt,
  });

  /// Unique local identifier.
  final String id;

  /// Full 16-digit PAN (digits only).
  final String pan;

  /// User-defined label (e.g. «کارت اصلی», «کارت سامان»).
  final String? title;

  /// Detected or custom bank name (e.g. «بانک سامان»).
  final String? bankName;

  /// Expiry month (2 digits: 01 to 12).
  final String? expMonth;

  /// Expiry year (2 digits: e.g. 05 for 1405).
  final String? expYear;

  /// CVV2 code (optional).
  final String? cvv2;

  /// When this card was saved.
  final DateTime? savedAt;

  /// Display name for the card.
  String get displayName {
    if (title != null && title!.trim().isNotEmpty) {
      return title!.trim();
    }
    final bank = bankName ?? detectBankName(pan);
    if (bank != null && bank.isNotEmpty) {
      return '$bank ($lastFourDigits)';
    }
    return 'کارت $lastFourDigits';
  }

  /// Clean digits-only PAN.
  String get cleanPan => pan.replaceAll(RegExp(r'\D'), '');

  /// Last 4 digits of the card number.
  String get lastFourDigits {
    final clean = cleanPan;
    if (clean.length >= 4) {
      return clean.substring(clean.length - 4);
    }
    return clean;
  }

  /// Formatted masked PAN for safe display: e.g. ۶۲۱۹-۸۶**-****-۳۷۶۹
  String get maskedPan {
    final clean = cleanPan;
    if (clean.length != 16) return pan;
    return '${clean.substring(0, 4)}-${clean.substring(4, 6)}**-****-${clean.substring(12, 16)}';
  }

  /// Formatted 16-digit PAN with spaces: e.g. 6219 8612 3456 3769
  String get formattedPan {
    final clean = cleanPan;
    if (clean.length != 16) return pan;
    return '${clean.substring(0, 4)} ${clean.substring(4, 8)} ${clean.substring(8, 12)} ${clean.substring(12, 16)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pan': cleanPan,
        'title': title,
        'bankName': bankName ?? detectBankName(pan),
        'expMonth': expMonth,
        'expYear': expYear,
        'cvv2': cvv2,
        'savedAt': savedAt?.toIso8601String(),
      };

  factory SavedBankCard.fromJson(Map<String, dynamic> json) => SavedBankCard(
        id: json['id'] as String,
        pan: (json['pan'] as String).replaceAll(RegExp(r'\D'), ''),
        title: json['title'] as String?,
        bankName: json['bankName'] as String?,
        expMonth: json['expMonth'] as String?,
        expYear: json['expYear'] as String?,
        cvv2: json['cvv2'] as String?,
        savedAt: json['savedAt'] != null
            ? DateTime.tryParse(json['savedAt'] as String)
            : null,
      );

  SavedBankCard copyWith({
    String? id,
    String? pan,
    String? title,
    String? bankName,
    String? expMonth,
    String? expYear,
    String? cvv2,
    DateTime? savedAt,
  }) =>
      SavedBankCard(
        id: id ?? this.id,
        pan: pan ?? this.pan,
        title: title ?? this.title,
        bankName: bankName ?? this.bankName,
        expMonth: expMonth ?? this.expMonth,
        expYear: expYear ?? this.expYear,
        cvv2: cvv2 ?? this.cvv2,
        savedAt: savedAt ?? this.savedAt,
      );
}

/// Identifies the issuing Iranian bank from the 6-digit IIN/BIN prefix.
String? detectBankName(String pan) {
  final clean = pan.replaceAll(RegExp(r'\D'), '');
  if (clean.length < 6) return null;
  final bin = clean.substring(0, 6);

  return switch (bin) {
    '603799' => 'بانک ملی',
    '621986' => 'بانک سامان',
    '610433' => 'بانک ملت',
    '589210' => 'بانک سپه',
    '627412' => 'بانک اقتصاد نوین',
    '622106' => 'بانک پارسیان',
    '502229' => 'بانک پاسارگاد',
    '627381' => 'بانک انصار',
    '502908' => 'بانک توسعه تعاون',
    '627353' => 'بانک تجارت',
    '589463' => 'بانک رفاه کارگران',
    '627648' => 'بانک توسعه صادرات',
    '627961' => 'بانک صنعت و معدن',
    '603770' => 'بانک کشاورزی',
    '628023' => 'بانک مسکن',
    '627760' => 'پست بانک ایران',
    '502938' => 'بانک دی',
    '606373' => 'بانک قرض‌الحسنه مهر ایران',
    '639346' => 'بانک سینا',
    '639607' => 'بانک سرمایه',
    '636214' => 'بانک آینده',
    '504706' => 'بانک شهر',
    '505801' => 'موسسه کوثر',
    '639599' => 'بانک قوامین',
    '606256' => 'موسسه اعتباری ملل',
    '628157' => 'موسسه اعتباری توسعه',
    _ => null,
  };
}
