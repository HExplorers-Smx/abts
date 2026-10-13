/// 应用元信息（与 pubspec.yaml 保持一致）
class AppMeta {
  AppMeta._();

  static const String name = '阿B听书';

  /// CI 构建时通过 --dart-define=APP_VERSION 注入"语义号.构建号"（如 0.2.5.44）；
  /// 本地直接跑时用默认值（与 pubspec.yaml 语义版本保持一致）
  static const String version =
      String.fromEnvironment('APP_VERSION', defaultValue: '0.2.5');
}
