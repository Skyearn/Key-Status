# Key Status

`Key Status` 是一个常驻菜单栏的 macOS 工具，用于在文本输入场景下显示当前输入状态。

## 当前功能

- 菜单栏显示 Caps Lock 状态（开/关）
- 支持切换应用图标（Caps On / Caps Off）
- 监听输入法切换与 Caps Lock 变化
- 在输入相关场景弹出 3 秒状态提示
- 浮层样式为小尺寸黑色图标卡片：左上角点位表示 Caps，中央显示输入法图标

## 技术实现

- 跨应用监听基于 macOS Accessibility（AX）
- 输入源读取基于 TIS（Text Input Source）
- 焦点与状态变化检测逻辑在：
  - `Key Status/FocusMonitor.swift`
  - `Key Status/InputSourceService.swift`
- 浮层显示在：
  - `Key Status/OverlayWindowController.swift`
- 菜单栏图标与 App 图标更新在：
  - `Key Status/StatusItemController.swift`

## 运行要求

- macOS 14+
- 首次运行需要授权：
  - 系统设置 > 隐私与安全性 > 辅助功能 > `Key Status`

## 构建方式

### Xcode

1. 打开 `Key Status.xcodeproj`
2. 选择 `Key Status` scheme
3. Build / Run

### 命令行（推荐）

```bash
./tools/build.sh
```

最终产物路径：

`./build/Key Status.app`

可选参数示例：

```bash
./tools/build.sh --release
./tools/build.sh --no-clean
./tools/build.sh --open
```

说明：脚本会自动处理扩展属性清理并对最终 `.app` 做本地签名，减少在同步目录中构建时出现签名失败的概率。

## 重要说明（避免“无法打开”）

建议统一在工程目录内构建和运行（`./build`），避免产物分散到其他位置。
如果工程本身位于会被文件提供器/同步系统改写扩展属性的目录（例如部分 iCloud 同步路径），可能出现“应用无法打开”。

建议做法：

- 编译过程使用 `./build/DerivedData`
- 对外测试使用 `./build/Key Status.app`
- 若必须复制到其他目录后出现打不开，先检查该 `.app` 是否被附加了异常扩展属性（如 `com.apple.FinderInfo`）

## 已知限制

- 作为独立 App（非输入法组件），跨应用 caret 获取受 AX 能力限制，部分控件可能不返回稳定插入点。
- 输入法图标来源依赖系统与输入法本身提供的资源，不同输入法可能表现不一致。

## 调试日志

运行日志默认写入系统日志目录（程序内固定逻辑）。
