import 'package:flutter/material.dart';

import 'ffi/sketch_kernel_ffi.dart';
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
            tooltip: 'Extrude closed profile',
            icon: const Icon(Icons.view_in_ar),
            onPressed: _extrude,
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
            child: Container(
              color: const Color(0xFF101418),
              child: SketchCanvas(controller: _controller),
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
