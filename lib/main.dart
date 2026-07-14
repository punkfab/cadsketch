import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'export/featuretree_export.dart';
import 'ffi/sketch_kernel.dart';
import 'sketch/mesh_import.dart';
import 'sketch/plane.dart';
// import 'ui/ai_panel.dart'; // AI assistant sidebar disabled for now — re-enable with the layout below.
import 'ui/assembly_view.dart';
import 'ui/scene_view.dart';
import 'ui/sketch_canvas.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On web this awaits the WASM kernel module; on native it's a no-op (the
  // library is dlopen'd synchronously). Either way the kernel is ready before
  // the first stroke is solved.
  await ensureKernelReady();
  runApp(const AiSketcherApp());
}

class AiSketcherApp extends StatelessWidget {
  const AiSketcherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ai-sketcher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const SketchHome(),
    );
  }
}

class SketchHome extends StatefulWidget {
  const SketchHome({super.key});

  @override
  State<SketchHome> createState() => _SketchHomeState();
}

class _SketchHomeState extends State<SketchHome> {
  final _controller = SketchController();

  // Probe the FFI bridge once at startup. If the kernel didn't build/bundle,
  // this surfaces here loudly rather than failing mysteriously on first stroke.
  late final String _kernelStatus = _probeKernel();

  String _probeKernel() {
    try {
      return 'kernel v${SketchKernel.instance.version}';
    } catch (e) {
      return 'kernel UNAVAILABLE: $e';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const _ImportPathDialog(),
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      final solid = importMeshFile(path.trim());
      final name = path.trim().split('/').last;
      _controller.importSolid(name, solid); // appears in the workspace scene
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _openPalette() async {
    final cmd = await showDialog<_Command>(
      context: context,
      builder: (_) => _CommandPalette(commands: _commands()),
    );
    if (cmd != null) await cmd.run();
  }

  Future<String?> _promptText() => showDialog<String>(
        context: context,
        builder: (_) => const _TextPromptDialog(),
      );

  Future<double?> _promptNumber(String title, String initial) async {
    final s = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
          title: title, hint: 'depth (mm)', initial: initial, caps: false),
    );
    return s == null ? null : double.tryParse(s.trim());
  }

  /// The command set behind ⌘K. Each is a point in the unified model — pick a
  /// datum (a plane / the active face) and a source (text, …); the rest of the
  /// pipeline is shared. Deliberately the same ops as the toolbar, one grammar.
  List<_Command> _commands() => [
        _Command('Text…', 'Place text on the active face / plane',
            Icons.text_fields, () async {
          final s = await _promptText();
          if (!mounted) return;
          if (s != null && s.trim().isNotEmpty) _controller.addText(s.trim());
        }),
        _Command('Extrude text…', 'Raise the active text/marks into 3D (emboss)',
            Icons.format_size, () async {
          final d = await _promptNumber('Extrude text', '12');
          if (!mounted) return;
          if (d != null) _controller.setEmbossDepth(d);
        }),
        _Command('Sketch on XY plane', 'New base-plane sketch',
            Icons.add_box_outlined, () async => _controller.addPlaneSketch(SketchPlane.xy)),
        _Command('Sketch on XZ plane', 'New base-plane sketch',
            Icons.add_box_outlined, () async => _controller.addPlaneSketch(SketchPlane.xz)),
        _Command('Sketch on YZ plane', 'New base-plane sketch',
            Icons.add_box_outlined, () async => _controller.addPlaneSketch(SketchPlane.yz)),
        _Command(
            'Export feature tree (IR)…',
            'Analyse the active part → featuretree IR (→ editable FreeCAD tree)',
            Icons.account_tree_outlined, () async {
          try {
            final path = writeFeatureTreeIr(_controller.active);
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Wrote $path — run it through '
                    'featuretree/gen.py for an editable FreeCAD tree')));
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Export failed: $e')));
          }
        }),
        _Command('Add part', 'Start a new empty body', Icons.add,
            () async => _controller.addPart()),
        _Command('Delete active part', 'Remove the current body',
            Icons.delete_outline, () async => _controller.removePart(_controller.activeIndex)),
        _Command('Clear active sketch', 'Erase the active part’s geometry',
            Icons.clear_all, () async => _controller.clear()),
      ];

  @override
  Widget build(BuildContext context) {
    final ok = _kernelStatus.startsWith('kernel v');
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => _openPalette(),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => _openPalette(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        title: const Text('ai-sketcher'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _kernelStatus,
                style: TextStyle(
                  fontSize: 12,
                  color: ok ? Colors.greenAccent : Colors.redAccent,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Commands (⌘K / Ctrl+K)',
            icon: const Icon(Icons.bolt_outlined),
            onPressed: _openPalette,
          ),
          PopupMenuButton<SketchPlane>(
            tooltip: 'New sketch on a base plane',
            icon: const Icon(Icons.add_box_outlined),
            onSelected: (pl) => _controller.addPlaneSketch(pl),
            itemBuilder: (_) => const [
              PopupMenuItem(value: SketchPlane.xy, child: Text('Sketch on XY')),
              PopupMenuItem(value: SketchPlane.xz, child: Text('Sketch on XZ')),
              PopupMenuItem(value: SketchPlane.yz, child: Text('Sketch on YZ')),
            ],
          ),
          IconButton(
            tooltip: 'Import mesh (STL/OBJ) as a part',
            icon: const Icon(Icons.upload_file),
            onPressed: _import,
          ),
          IconButton(
            tooltip: 'Cross-part mates (assembly view)',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => AssemblyView(controller: _controller)),
            ),
          ),
          IconButton(
            tooltip: 'Shared parameters',
            icon: const Icon(Icons.tune),
            onPressed: () => showDialog(
              context: context,
              builder: (_) => _ParametersDialog(controller: _controller),
            ),
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: _controller.clear,
          ),
        ],
      ),
      body: Column(
        children: [
          _PartsBar(controller: _controller),
          // AI assistant sidebar disabled for now. To restore, wrap SceneView in
          // a Row and add `AiPanel(controller: _controller)` after it (and
          // uncomment the ai_panel.dart import above).
          Expanded(child: SceneView(controller: _controller)),
        ],
      ),
        ),
      ),
    );
  }
}

/// Horizontal bar of part chips with an add button — switch the active part
/// without leaving the canvas (the "jump between parts" UX).
class _PartsBar extends StatelessWidget {
  const _PartsBar({required this.controller});

  final SketchController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Container(
        height: 48,
        color: const Color(0xFF161C22),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: controller.parts.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  final selected = i == controller.activeIndex;
                  return Center(
                    child: ChoiceChip(
                      label: Text(controller.parts[i].name),
                      selected: selected,
                      onSelected: (_) => controller.setActive(i),
                    ),
                  );
                },
              ),
            ),
            IconButton(
              tooltip: 'Add part',
              icon: const Icon(Icons.add),
              onPressed: controller.addPart,
            ),
          ],
        ),
      ),
    );
  }
}

/// Lists shared parameters; editing a value re-solves every part that binds it
/// (the parametric-assembly payoff: one edit drives many parts).
class _ParametersDialog extends StatelessWidget {
  const _ParametersDialog({required this.controller});

  final SketchController controller;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Shared parameters'),
      content: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final names = controller.parameters.keys.toList()..sort();
          if (names.isEmpty) {
            return const SizedBox(
              width: 320,
              child: Text(
                'No parameters yet. Tap a dimension on the canvas and bind it to '
                'a new parameter name to create one.',
                style: TextStyle(color: Colors.white70),
              ),
            );
          }
          return SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final name in names)
                  _ParamRow(
                    name: name,
                    value: controller.parameters[name]!,
                    onChanged: (v) => controller.setParameter(name, v),
                  ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ParamRow extends StatefulWidget {
  const _ParamRow({required this.name, required this.value, required this.onChanged});

  final String name;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_ParamRow> createState() => _ParamRowState();
}

class _ParamRowState extends State<_ParamRow> {
  late final _field = TextEditingController(text: widget.value.toStringAsFixed(1));

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit(String s) {
    final v = double.tryParse(s);
    if (v != null && v > 0) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(widget.name)),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _field,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textInputAction: TextInputAction.done,
              onSubmitted: _submit,
              decoration: const InputDecoration(isDense: true),
            ),
          ),
        ],
      ),
    );
  }
}

/// Prompts for a mesh file path to import (.stl / .obj). A native file picker
/// is a later refinement; typing/pasting a path keeps the harness dependency-free.
class _ImportPathDialog extends StatefulWidget {
  const _ImportPathDialog();

  @override
  State<_ImportPathDialog> createState() => _ImportPathDialogState();
}

class _ImportPathDialogState extends State<_ImportPathDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import mesh'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _field,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Path to .stl or .obj',
              hintText: '/home/you/part.stl',
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 8),
          const Text('STEP? Convert to STL/OBJ (FreeCAD) for now.',
              style: TextStyle(fontSize: 11, color: Colors.white54)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _field.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

/// One entry in the ⌘K palette: a label, a hint, and the action to run.
class _Command {
  const _Command(this.label, this.subtitle, this.icon, this.run);
  final String label;
  final String subtitle;
  final IconData icon;
  final Future<void> Function() run;
}

/// The ⌘K command palette: a single search field over the command set. The
/// "conversational" surface — because the model is unified, the command list is
/// small and composable. Enter runs the top match; tap runs any.
class _CommandPalette extends StatefulWidget {
  const _CommandPalette({required this.commands});

  final List<_Command> commands;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final _field = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  List<_Command> get _filtered {
    final q = _query.toLowerCase().trim();
    if (q.isEmpty) return widget.commands;
    return widget.commands
        .where((c) =>
            c.label.toLowerCase().contains(q) ||
            c.subtitle.toLowerCase().contains(q))
        .toList();
  }

  void _runTop() {
    final f = _filtered;
    if (f.isNotEmpty) Navigator.pop(context, f.first);
  }

  @override
  Widget build(BuildContext context) {
    final results = _filtered;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 96, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: TextField(
                controller: _field,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.bolt),
                  hintText: 'Type a command…  (e.g. text)',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
                onSubmitted: (_) => _runTop(),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: results.length,
                itemBuilder: (context, i) {
                  final c = results[i];
                  return ListTile(
                    leading: Icon(c.icon, size: 20),
                    title: Text(c.label),
                    subtitle: Text(c.subtitle),
                    onTap: () => Navigator.pop(context, c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prompts for a single string (text to place, or a number typed as text).
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    this.title = 'Text',
    this.hint = 'e.g. M3',
    this.initial = '',
    this.caps = true,
  });

  final String title;
  final String hint;
  final String initial;
  final bool caps;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _field,
        autofocus: true,
        textCapitalization: widget.caps
            ? TextCapitalization.characters
            : TextCapitalization.none,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _field.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}
