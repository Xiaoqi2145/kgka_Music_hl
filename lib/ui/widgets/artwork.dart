import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/artwork_cache_service.dart';

class Artwork extends StatefulWidget {
  const Artwork({
    super.key,
    this.url,
    required this.size,
    this.borderRadius = 8,
    this.icon = Icons.music_note_rounded,
  });

  final String? url;
  final double size;
  final double borderRadius;
  final IconData icon;

  @override
  State<Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<Artwork> {
  File? _cachedFile;
  String? _loadedUrl;
  bool _cacheResolved = false;

  @override
  void initState() {
    super.initState();
    _load(widget.url);
  }

  @override
  void didUpdateWidget(covariant Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _cachedFile = null;
      _loadedUrl = null;
      _cacheResolved = false;
      _load(widget.url);
    }
  }

  Future<void> _load(String? url) async {
    if (url == null || url.isEmpty) return;
    final file = await ArtworkCacheService.instance.load(url);
    if (!mounted || widget.url != url) return;
    setState(() {
      _cachedFile = file;
      _loadedUrl = url;
      _cacheResolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.url;
    final file = _loadedUrl == imageUrl ? _cachedFile : null;
    final child = imageUrl == null || imageUrl.isEmpty
        ? _Fallback(icon: widget.icon)
        : !_cacheResolved || _loadedUrl != imageUrl
        ? _ShimmerBox(size: widget.size, borderRadius: widget.borderRadius)
        : file != null
        ? Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _Fallback(icon: widget.icon),
          )
        : _Fallback(icon: widget.icon);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: widget.size.isFinite
          ? SizedBox.square(dimension: widget.size, child: child)
          : SizedBox.expand(child: child),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: .88),
            const Color(0xFF70D6FF),
            colorScheme.secondary.withValues(alpha: .72),
          ],
        ),
      ),
      child: Icon(icon, color: Colors.white, size: 28),
    );
  }
}

/// 图片加载时的 Shimmer 占位效果。
class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox({required this.size, required this.borderRadius});

  final double size;
  final double borderRadius;

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _animation = Tween(begin: -1.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainer;
    final highlightColor = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: .4)
        : Colors.white.withValues(alpha: .6);

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(_animation.value - 0.5, 0),
                end: Alignment(_animation.value + 0.5, 0),
                colors: [baseColor, highlightColor, baseColor],
                stops: const [0, 0.5, 1],
              ),
            ),
            child: child,
          ),
        );
      },
      child: SizedBox(
        width: widget.size.isFinite ? widget.size : null,
        height: widget.size.isFinite ? widget.size : null,
      ),
    );
  }
}
