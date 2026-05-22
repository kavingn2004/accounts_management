import 'package:flutter/material.dart';

import '../../core/theme.dart';

enum AlertSeverity { critical, warning, info }

extension AlertSeverityX on AlertSeverity {
  Color get color => switch (this) {
        AlertSeverity.critical => AppTheme.cExpense,
        AlertSeverity.warning => AppTheme.cBills,
        AlertSeverity.info => AppTheme.primary,
      };

  IconData get icon => switch (this) {
        AlertSeverity.critical => Icons.error_outline,
        AlertSeverity.warning => Icons.warning_amber_rounded,
        AlertSeverity.info => Icons.info_outline,
      };

  int get rank => switch (this) {
        AlertSeverity.critical => 0,
        AlertSeverity.warning => 1,
        AlertSeverity.info => 2,
      };
}

/// An alert shown to the user. Most are computed from data (id == null);
/// user-created ones are stored and carry the row [id] so they can be deleted.
class AppAlert {
  AppAlert({
    required this.key,
    required this.severity,
    required this.title,
    required this.message,
    this.id,
  });

  /// Stable identity used for read/unread tracking.
  final String key;
  final AlertSeverity severity;
  final String title;
  final String message;

  /// Non-null for user-created (stored) alerts.
  final String? id;

  bool get isCustom => id != null;
}

AlertSeverity alertSeverityFrom(Object? s) => switch (s) {
      'critical' => AlertSeverity.critical,
      'warning' => AlertSeverity.warning,
      _ => AlertSeverity.info,
    };
