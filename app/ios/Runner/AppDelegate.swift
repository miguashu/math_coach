import Flutter
import UIKit
import UniformTypeIdentifiers

/// 宿主 AppDelegate。
///
/// 除了模板自带的两行，这里还注册了一个平台通道 `mathcoach/storage`，
/// 与安卓侧 `MainActivity.java` 是**同一套接口**（Dart 侧只认方法名）：
///
/// | 方法           | 入参         | 返回                      |
/// |---------------|--------------|--------------------------|
/// | filesDir      | 无           | 数据目录绝对路径           |
/// | share         | path, mime   | 是否成功唤起分享面板       |
/// | takePhoto     | 无           | 拍到的照片路径 / null      |
/// | pickImage     | 无           | 相册选中并拷进 App 的路径  |
/// | pickDocument  | 无           | 备份文件拷进 App 后的路径  |
///
/// ## 为什么通道代码写在这个文件里，而不是单独一个 Swift 文件
///
/// iOS 新增源文件必须同时登记到 `project.pbxproj` 的四处
/// （PBXBuildFile / PBXFileReference / PBXGroup / PBXSourcesBuildPhase），
/// 而生成这套工程的本机是 Windows，改完无法编译验证。
/// 写进已在编译列表里的 AppDelegate.swift 就完全绕开了这个风险。
///
/// ## ⚠️ 这份代码没有在 macOS 上编译验证过
///
/// 只做过官方 API 签名的人工比对。首次在 Mac 上构建如果报错，
/// 最快的兜底是把下面 `MathCoachChannel.register(...)` 那行注释掉 ——
/// App 仍能正常启动、出题、判分、复习（全在 Dart 内核里），
/// 只是拍照 / 导出分享 / 备份导入用不了。Dart 侧对这些方法缺失是容错的
/// （参考 app/lib/state.dart 里对 MissingPluginException 的处理）。
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    MathCoachChannel.register(with: engineBridge.pluginRegistry)
  }
}

// MARK: - 平台通道 mathcoach/storage

final class MathCoachChannel: NSObject {

  private static let channelName = "mathcoach/storage"

  /// 相机与相册是异步回结果的，Result 得先存着。
  private var pendingResult: FlutterResult?
  /// picker 的 delegate 是弱引用持有的，这里要留一份强引用，否则会提前释放。
  private var activeDelegate: PickerDelegate?

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "MathCoachStorage") else { return }
    let instance = MathCoachChannel()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "filesDir":
      result(dataDir())

    case "share":
      let args = call.arguments as? [String: Any]
      let path = args?["path"] as? String
      let mime = args?["mime"] as? String
      result(shareFile(path, mime: mime))

    case "takePhoto":
      pendingResult = result
      if !presentImagePicker(source: .camera) {
        pendingResult = nil
        result(nil)
      }

    case "pickImage":
      pendingResult = result
      if !presentImagePicker(source: .photoLibrary) {
        pendingResult = nil
        result(nil)
      }

    case "pickDocument":
      pendingResult = result
      if !presentDocumentPicker() {
        pendingResult = nil
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func finish(_ value: String?) {
    let r = pendingResult
    pendingResult = nil
    activeDelegate = nil
    r?(value)
  }

  // MARK: 数据目录

  /// iOS 上放 Documents —— 配合 Info.plist 里的 `UIFileSharingEnabled`
  /// 与 `LSSupportsOpeningDocumentsInPlace`，家长能在系统「文件」App 里
  /// 直接看到导出的练习卷 PDF，不用连电脑。
  private func dataDir() -> String {
    let fm = FileManager.default
    let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("math_coach", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir.path
  }

  // MARK: 分享

  /// 唤起系统分享面板（发给微信 / 邮件 / 打印）。
  /// 任何一步失败都返回 false 而不抛异常 —— 分享失败不该影响 App。
  private func shareFile(_ path: String?, mime: String?) -> Bool {
    guard let path = path, !path.isEmpty else { return false }
    guard FileManager.default.fileExists(atPath: path) else {
      NSLog("[MathCoach] share: file not found \(path)")
      return false
    }
    guard let host = Self.topViewController() else { return false }

    let url = URL(fileURLWithPath: path)
    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    // iPad 上不给锚点会直接崩，这里兜一下
    if let pop = activity.popoverPresentationController {
      pop.sourceView = host.view
      pop.sourceRect = CGRect(x: host.view.bounds.midX,
                              y: host.view.bounds.midY,
                              width: 0, height: 0)
      pop.permittedArrowDirections = []
    }
    host.present(activity, animated: true)
    return true
  }

  /// 找当前最上层可用来 present 的控制器。
  /// Flutter 用上 SceneDelegate 之后，AppDelegate 的 window 不一定是 key window，
  /// 所以从 connectedScenes 里找。
  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow })
      ?? scenes.first?.windows.first
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController {
      vc = presented
    }
    return vc
  }

  // MARK: 相机 / 相册

  private func presentImagePicker(source: UIImagePickerController.SourceType) -> Bool {
    if source == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) {
      // 模拟器上必然没有相机，真机才有
      NSLog("[MathCoach] 这台设备没有相机")
      return false
    }
    guard let host = Self.topViewController() else { return false }

    let picker = UIImagePickerController()
    picker.sourceType = source
    picker.mediaTypes = ["public.image"]

    let delegate = PickerDelegate(
      onImage: { [weak self] image in
        guard let self = self else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else {
          self.finish(nil)
          return
        }
        self.finish(self.writePhoto(data))
      },
      onCancel: { [weak self] in
        self?.finish(nil)
      }
    )
    activeDelegate = delegate
    picker.delegate = delegate
    host.present(picker, animated: true)
    return true
  }

  /// 照片存进 App 目录 —— 相册给的临时文件出了回调就可能失效。
  private func writePhoto(_ data: Data) -> String? {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: dataDir()).appendingPathComponent("photos", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let out = dir.appendingPathComponent("photo_\(ts).jpg")
    do {
      try data.write(to: out)
      return out.path
    } catch {
      NSLog("[MathCoach] 写照片失败 \(error)")
      return nil
    }
  }

  // MARK: 文档选择器（导入备份）

  /// 挑一份备份 JSON。走系统选择器，不碰任何隐私权限 ——
  /// 这个 App 至今 0 权限，不能为了一个"导入"破例。
  private func presentDocumentPicker() -> Bool {
    guard let host = Self.topViewController() else { return false }

    // json 在个别系统上不给选，那就退到"所有文件"，
    // 格式对不对交给 Dart 侧的 BackupCodec 判（判错会给明确提示）。
    var types: [UTType] = []
    if let json = UTType(filenameExtension: "json") {
      types = [json]
    } else {
      types = [.data]
    }

    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
    picker.allowsMultipleSelection = false

    let delegate = PickerDelegate(
      onDocument: { [weak self] url in
        guard let self = self else { return }
        self.finish(self.importDocument(url))
      },
      onCancel: { [weak self] in
        self?.finish(nil)
      }
    )
    activeDelegate = delegate
    picker.delegate = delegate
    host.present(picker, animated: true)
    return true
  }

  /// asCopy: true 已经把文件拷到临时目录，这里再规整地放进 App 的 backups/。
  private func importDocument(_ url: URL) -> String? {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: dataDir()).appendingPathComponent("backups", isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let out = dir.appendingPathComponent("import_\(ts).json")
    do {
      if fm.fileExists(atPath: out.path) {
        try fm.removeItem(at: out)
      }
      try fm.copyItem(at: url, to: out)
      return out.path
    } catch {
      NSLog("[MathCoach] 导入备份失败 \(error)")
      return nil
    }
  }
}

/// 把 UIKit 的几个 delegate 收在一个小类里，避免 MathCoachChannel
/// 被 `@objc` 方法签名撑得难读。用闭包把结果回传出去。
private final class PickerDelegate: NSObject,
                                   UIImagePickerControllerDelegate,
                                   UINavigationControllerDelegate,
                                   UIDocumentPickerDelegate {

  private let onImage: (UIImage) -> Void
  private let onDocument: (URL) -> Void
  private let onCancel: () -> Void

  init(onImage: @escaping (UIImage) -> Void = { _ in },
       onDocument: @escaping (URL) -> Void = { _ in },
       onCancel: @escaping () -> Void) {
    self.onImage = onImage
    self.onDocument = onDocument
    self.onCancel = onCancel
  }

  // 相册 / 相机
  func imagePickerController(_ picker: UIImagePickerController,
                             didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    if let image = info[.originalImage] as? UIImage {
      onImage(image)
    } else {
      onCancel()
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    onCancel()
  }

  // 文件
  func documentPicker(_ controller: UIDocumentPickerViewController,
                      didPickDocumentsAt urls: [URL]) {
    guard let first = urls.first else {
      onCancel()
      return
    }
    onDocument(first)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    onCancel()
  }
}
