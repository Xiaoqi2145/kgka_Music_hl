String formatPlayCount(int? value) {
  if (value == null) return '精选歌单';
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)} 万次播放';
  return '$value 次播放';
}
