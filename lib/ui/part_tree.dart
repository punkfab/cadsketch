import 'package:flutter/material.dart';

import '../sketch/entities.dart';
import '../sketch/part.dart';
import 'sketch_canvas.dart';

/// A collapsible left panel showing the parts as a tree: base bodies at the
/// root, face features nested under the body they were sketched on, and under
/// each part its Sketch (line/circle counts) and mate points. Replaces the flat
/// tab strip now that parts have a parent/child hierarchy. Tap a row to make its
/// part active; a per-part menu duplicates or deletes it.
class PartTree extends StatefulWidget {
  const PartTree({super.key, required this.controller});

  final SketchController controller;

  @override
  State<PartTree> createState() => _PartTreeState();
}

class _PartTreeState extends State<PartTree> {
  bool _open = true;
  // Parts whose children are hidden (default: expanded). Keyed by identity so it
  // survives reordering.
  final Set<Part> _collapsed = <Part>{};

  static const _bg = Color(0xFF161C22);
  static const _accent = Color(0xFF4DD0E1);
  static const _amber = Color(0xFFFFC857);

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return Container(
        width: 40,
        color: _bg,
        child: Column(
          children: [
            IconButton(
              tooltip: 'Show parts tree',
              icon: const Icon(Icons.account_tree_outlined, size: 20),
              color: Colors.white70,
              onPressed: () => setState(() => _open = true),
            ),
          ],
        ),
      );
    }
    return Container(
      width: 232,
      color: _bg,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: _rows(),
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              TextButton.icon(
                onPressed: widget.controller.addPart,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add part'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  foregroundColor: Colors.white70,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 4, top: 8, bottom: 8),
      child: Row(
        children: [
          const Text('Parts',
              style: TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            tooltip: 'Hide parts tree',
            icon: const Icon(Icons.chevron_left, size: 20),
            color: Colors.white54,
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _open = false),
          ),
        ],
      ),
    );
  }

  // --- Tree flattening: roots (no parent) then their descendants, honoring the
  // per-part collapse state. Each part is followed by its Sketch + mates nodes.

  List<Widget> _rows() {
    final parts = widget.controller.parts;
    final indexOf = <Part, int>{for (var i = 0; i < parts.length; i++) parts[i]: i};
    final childrenOf = <Part, List<Part>>{};
    final roots = <Part>[];
    for (final p in parts) {
      final parent = p.parent;
      if (parent != null && indexOf.containsKey(parent)) {
        childrenOf.putIfAbsent(parent, () => []).add(p);
      } else {
        roots.add(p);
      }
    }

    final rows = <Widget>[];
    void visit(Part p, int depth) {
      final i = indexOf[p]!;
      final kids = childrenOf[p] ?? const <Part>[];
      final expandable = kids.isNotEmpty;
      final expanded = !_collapsed.contains(p);
      rows.add(_partRow(p, i, depth, expandable: expandable, expanded: expanded));
      if (expanded) {
        rows.add(_leafRow(
          depth + 1,
          Icons.gesture,
          _sketchLabel(p),
          () => widget.controller.setActive(i),
          active: i == widget.controller.activeIndex,
        ));
        if (p.connectors.isNotEmpty) {
          rows.add(_leafRow(
            depth + 1,
            Icons.push_pin_outlined,
            '${p.connectors.length} mate point${p.connectors.length == 1 ? '' : 's'}',
            () => widget.controller.setActive(i),
            color: _amber,
          ));
        }
        for (final c in kids) {
          visit(c, depth + 1);
        }
      }
    }

    for (final r in roots) {
      visit(r, 0);
    }
    return rows;
  }

  Widget _partRow(Part p, int index, int depth,
      {required bool expandable, required bool expanded}) {
    final active = index == widget.controller.activeIndex;
    final isFeature = p.parent != null;
    final subtitle = !isFeature ? 'body' : (p.isSubtractive ? 'pocket' : 'boss');
    final icon = !isFeature
        ? Icons.view_in_ar
        : (p.isSubtractive ? Icons.remove_circle_outline : Icons.add_circle_outline);
    final iconColor =
        !isFeature ? Colors.white70 : (p.isSubtractive ? const Color(0xFFE57373) : const Color(0xFF81C784));

    return InkWell(
      onTap: () => widget.controller.setActive(index),
      child: Container(
        color: active ? _accent.withValues(alpha: 0.16) : null,
        padding: EdgeInsets.only(left: 4.0 + depth * 14, right: 2),
        height: 34,
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: expandable
                  ? IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      iconSize: 18,
                      color: Colors.white54,
                      icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
                      onPressed: () => setState(() =>
                          expanded ? _collapsed.add(p) : _collapsed.remove(p)),
                    )
                  : null,
            ),
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? _accent : Colors.white,
                  fontSize: 12.5,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(subtitle,
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
            _partMenu(index),
          ],
        ),
      ),
    );
  }

  Widget _partMenu(int index) {
    return PopupMenuButton<String>(
      tooltip: 'Part actions',
      padding: EdgeInsets.zero,
      iconSize: 16,
      icon: const Icon(Icons.more_vert, color: Colors.white38),
      onSelected: (v) {
        switch (v) {
          case 'duplicate':
            widget.controller.duplicatePart(index);
          case 'delete':
            widget.controller.removePart(index);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
        PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
  }

  Widget _leafRow(int depth, IconData icon, String label, VoidCallback onTap,
      {bool active = false, Color? color}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: active ? _accent.withValues(alpha: 0.10) : null,
        padding: EdgeInsets.only(left: 4.0 + depth * 14 + 22, right: 8),
        height: 28,
        child: Row(
          children: [
            Icon(icon, size: 14, color: color ?? Colors.white38),
            const SizedBox(width: 6),
            Expanded(
              child: Text(label,
                  style: TextStyle(color: color ?? Colors.white60, fontSize: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }

  String _sketchLabel(Part p) {
    final lines = p.sketch.segments.length;
    final circles = p.decorations.whereType<CircleEntity>().length;
    final parts = <String>[
      if (lines > 0) '$lines line${lines == 1 ? '' : 's'}',
      if (circles > 0) '$circles circle${circles == 1 ? '' : 's'}',
    ];
    return 'Sketch${parts.isEmpty ? ' — empty' : ' — ${parts.join(', ')}'}';
  }
}
