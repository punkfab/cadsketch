import 'package:flutter/material.dart';

import 'ffi/sketch_kernel_ffi.dart';
import 'sketch/mesh_import.dart';
import 'ui/ai_panel.dart';
import 'ui/assembly_view.dart';
import 'ui/sketch_canvas.dart';
import 'ui/solid_view.dart';

void main() {
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
      _controller.importSolid(name, solid);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SolidView(controller: _controller)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  void _extrude() {
    if (_controller.active.buildSolid() == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Draw a single closed profile (e.g. a box) to extrude'),
      ));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SolidView(controller: _controller)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ok = _kernelStatus.startsWith('kernel v');
    return Scaffold(
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
            tooltip: 'Import mesh (STL/OBJ) as a part',
            icon: const Icon(Icons.upload_file),
            onPressed: _import,
          ),
          IconButton(
            tooltip: 'Extrude closed profile',
            icon: const Icon(Icons.view_in_ar),
            onPressed: _extrude,
          ),
          IconButton(
            tooltip: 'Assembly (mate parts)',
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
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    color: const Color(0xFF101418),
                    child: SketchCanvas(controller: _controller),
                  ),
                ),
                AiPanel(controller: _controller),
              ],
            ),
          ),
        ],
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
