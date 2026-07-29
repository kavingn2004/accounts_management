import 'package:flutter/material.dart';

import 'theme.dart';

/// Flat, bordered surface. Depth in this design comes from tone and hairlines,
/// never from elevation — so there is deliberately no shadow parameter.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rCard),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.rCard),
      child: content,
    );
  }
}

/// 32px tinted square holding a module glyph. This is the *only* place a
/// module's category colour is allowed to appear.
class IconChip extends StatelessWidget {
  const IconChip(this.icon, this.tone, {super.key, this.size = 32});

  final IconData icon;
  final ModuleTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone.chip(context),
        borderRadius: BorderRadius.circular(AppTheme.rChip),
      ),
      child: Icon(icon, size: size / 2, color: tone.of(context)),
    );
  }
}

/// Any figure that sits in a column. Always tabular so rows line up.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.value, {
    super.key,
    this.style,
    this.color,
    this.serif = false,
  });

  final String value;
  final TextStyle? style;
  final Color? color;
  final bool serif;

  @override
  Widget build(BuildContext context) {
    final base = style ??
        (serif
            ? context.text.displaySmall
            : context.text.titleSmall);
    return Text(
      value,
      style: base?.copyWith(color: color, fontFeatures: tabular),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Small uppercase group heading ("SECURITY", "PREFERENCES").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: context.text.labelMedium?.copyWith(
          color: context.colors.textSecondary,
          letterSpacing: 0.72,
        ),
      ),
    );
  }
}

/// Dashboard metric: icon chip over label / value / delta. The value is always
/// primary ink — the tone only tints the chip.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.tone,
    required this.label,
    required this.value,
    this.delta,
    this.deltaColor,
    this.onTap,
  });

  final IconData icon;
  final ModuleTone tone;
  final String label;
  final String value;
  final String? delta;
  final Color? deltaColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          IconChip(icon, tone),
          const SizedBox(height: 6),
          Text(
            label,
            style: context.text.labelMedium?.copyWith(color: c.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          MoneyText(
            value,
            style: context.text.titleMedium?.copyWith(fontSize: 17),
          ),
          if (delta != null) ...[
            const SizedBox(height: 2),
            Text(
              delta!,
              style: context.text.labelSmall?.copyWith(
                color: deltaColor ?? c.textSecondary,
                fontFeatures: tabular,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// 64px list row: icon chip · title/subtitle · trailing amount, separated by
/// hairlines rather than wrapped in per-row cards.
class AppListRow extends StatelessWidget {
  const AppListRow({
    super.key,
    required this.icon,
    required this.tone,
    required this.title,
    this.subtitle,
    this.trailing,
    this.trailingColor,
    this.onTap,
    this.onLongPress,
    this.showTopBorder = true,
  });

  final IconData icon;
  final ModuleTone tone;
  final String title;
  final String? subtitle;
  final String? trailing;
  final Color? trailingColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showTopBorder;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        height: AppTheme.rowHeight,
        decoration: BoxDecoration(
          border: showTopBorder
              ? Border(top: BorderSide(color: c.border))
              : null,
        ),
        child: Row(
          children: [
            IconChip(icon, tone),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: context.text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: context.text.bodyMedium
                          ?.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              MoneyText(trailing!, color: trailingColor),
            ],
          ],
        ),
      ),
    );
  }
}

/// Pill used by the filter bars. Selected state is a clay tint plus a clay
/// border — never a solid fill, which would fight the FAB for attention.
class AppFilterChip extends StatelessWidget {
  const AppFilterChip({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.rChip),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? c.accent.withValues(alpha: c.chipAlpha)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? c.accent.withValues(alpha: 0.32)
                : c.border,
          ),
          borderRadius: BorderRadius.circular(AppTheme.rChip),
        ),
        child: Text(
          label,
          style: context.text.labelMedium?.copyWith(
            color: selected ? c.textPrimary : c.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Grab handle at the top of a modal sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 18),
        decoration: BoxDecoration(
          color: context.colors.border,
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );
  }
}

/// Settings-style row: label · value · chevron, separated by hairlines.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
    this.isLast = false,
  });

  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: c.border),
            bottom: isLast ? BorderSide(color: c.border) : BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: context.text.bodyLarge)),
            if (value != null)
              Text(
                value!,
                style: context.text.bodySmall?.copyWith(color: c.textSecondary),
              ),
            if (trailing != null) trailing!,
            if (trailing == null && onTap != null) ...[
              const SizedBox(width: 12),
              Icon(Icons.chevron_right, size: 18, color: c.textSecondary),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bordered empty state — serif line plus a sentence of explanation.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.message});

  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(AppTheme.rFab),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: context.text.titleLarge?.copyWith(fontSize: 18)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              style: context.text.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}
