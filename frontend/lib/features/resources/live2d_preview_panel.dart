import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import '../../core/api_client.dart';
import '../../core/app_theme.dart';

/// Live2D Preview Panel - Model browser and expression preview.
class Live2DPreviewPanel extends StatefulWidget {
  const Live2DPreviewPanel({super.key});

  @override
  State<Live2DPreviewPanel> createState() => _Live2DPreviewPanelState();
}

class _Live2DPreviewPanelState extends State<Live2DPreviewPanel> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _models = [];
  Map<String, dynamic>? _selectedModel;
  String? _selectedExpression;
  
  // Animation playback state
  bool _isPlaying = false;
  double _currentTime = 0.0;

  Future<void> _loadModels() async {
    try {
      final res = await ApiClient.instance.get('/plugin/live2d/models');
      
      setState(() {
        _models = (res['models'] as List?)?.map((m) => m as Map<String, dynamic>).toList() ?? [];
        _isLoading = false;
        
        if (_models.isNotEmpty) {
          _selectModel(_models[0]);
        }
      });
    } catch (e) {
      print('[Live2DPreview] Failed to load models: $e');
      setState(() => _isLoading = false);
    }
  }

  void _selectModel(Map<String, dynamic> model) {
    setState(() {
      _selectedModel = model;
      _selectedExpression = model['expressions']?.isNotEmpty == true 
          ? model['expressions'][0] 
          : null;
      _currentTime = 0.0;
    });
  }

  void _togglePlayback() {
    setState(() {
      _isPlaying = !_isPlaying;
      
      if (_isPlaying) {
        _startAnimation();
      } else {
        _stopAnimation();
      }
    });
  }

  void _startAnimation() {
    Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      setState(() {
        _currentTime += 0.1;
        
        if (_currentTime > 10.0) {
          _currentTime = 0.0;
        }
      });
    });
  }

  void _stopAnimation() {
    // Timer automatically cancels on dispose
  }

  Widget _buildModelGrid() {
    if (_models.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              FluentIcons.person_24_regular,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            const Text(
              '暂无 Live2D 模型',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.8,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _models.length,
      itemBuilder: (context, index) {
        final model = _models[index];
        final isSelected = _selectedModel?['id'] == model['id'];
        
        return Card(
          color: isSelected
              ? (Theme.of(context).brightness == Brightness.light
                  ? Colors.blue.shade50
                  : Colors.blue.withOpacity(0.1))
              : null,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _selectModel(model),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    height: 120,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          _getModelColor(model).withOpacity(0.3),
                          Colors.transparent,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${model['expressions']?.length ?? 0}',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white),
                            ),
                          ),
                        ),
                        Center(
                          child: Icon(
                            FluentIcons.person_24_regular,
                            size: 48,
                            color: _getModelColor(model),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  model['id'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                Text(
                  '${model['expressions']?.length ?? 0} 个表情',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  Color _getModelColor(Map<String, dynamic> model) {
    // Generate consistent color based on model ID hash
    final hash = model['id'].hashCode.abs();
    final hue = hash % 360;
    return HSLColor.fromAHSL(
      0.8,
      hue.toDouble(),
      0.6,
      0.5,
    ).toColor();
  }

  Widget _buildPreviewSection() {
    if (_selectedModel == null) {
      return const SizedBox.shrink();
    }

    final expressions = _selectedModel!['expressions'] as List<dynamic>? ?? [];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // Preview area
          Container(
            height: 300,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.grey.shade100,
                  Colors.grey.shade50,
                ],
              ),
            ),
            child: Stack(
              children: [
                // Actual preview would be loaded from asset extractor or render service
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 48,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_selectedExpression?.toUpperCase() ?? "NO PREVIEW"}',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Playback controls overlay
                if (_isPlaying)
                  Positioned(
                    bottom: 8,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(
                      value: _currentTime / 10.0,
                      minHeight: 2,
                      backgroundColor: Colors.grey.shade300,
                    ),
                  ),
              ],
            ),
          ),
          
          // Expression selector
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: expressions.map((expr) {
                  final isSelected = _selectedExpression == expr;
                  
                  return ElevatedButton(
                    key: ValueKey(expr),
                    onPressed: () {
                      setState(() => _selectedExpression = expr);
                      // Trigger actual rendering here
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isSelected
                          ? Theme.of(context).primaryColor
                          : Colors.grey.shade200,
                      foregroundColor:
                          isSelected ? Colors.white : Colors.black87,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: Text(
                        expr.toString().capitalize(),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          
          // Playback control bar
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.light
                  ? Colors.grey.shade50
                  : Colors.grey.shade900,
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(FluentIcons.stop_24_regular),
                  tooltip: '停止播放',
                  onPressed: _togglePlayback,
                  color: _isPlaying ? Colors.red : Colors.grey,
                ),
                Text(
                  '播放时长：${_currentTime.toStringAsFixed(1)}s',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                IconButton(
                  icon: Icon(
                    _isPlaying 
                        ? Icons.pause_rounded 
                        : Icons.play_arrow_rounded,
                  ),
                  tooltip: _isPlaying ? '暂停' : '播放',
                  onPressed: _togglePlayback,
                  color: _isPlaying ? Colors.blue : Colors.grey,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Header toolbar
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Text(
                'Live2D 模型库',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _loadModels,
                icon: const Icon(FluentIcons.arrow_sync_24_regular),
                label: const Text('刷新列表'),
              ),
            ],
          ),
        ),
        
        // Split view
        Expanded(
          child: Row(
            children: [
              // Model list panel
              Container(
                width: 250,
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: Colors.grey.shade200,
                      width: 1,
                    ),
                  ),
                ),
                child: _buildModelGrid(),
              ),
              
              // Preview panel
              Expanded(
                child: _selectedModel == null
                    ? const Center(child: Text('请选择一个模型'))
                    : _buildPreviewSection(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Extension for capitalize
extension StringX on String {
  String capitalize() {
    if (isEmpty) return this;
    return this[0].toUpperCase() + substring(1);
  }
}
