package com.mathcoach.app;

import android.content.Intent;
import android.net.Uri;
import android.provider.MediaStore;
import android.os.Bundle;
import android.util.Log;

import androidx.core.content.FileProvider;

import java.io.File;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 宿主 Activity。
 *
 * 这里只做两件事：告诉 Dart 侧数据放在哪个目录，以及把导出好的 PDF
 * 交给系统的分享面板。
 * 刻意不打包任何第三方插件 —— 题目、答案、几何坐标全部在本地算，
 * 这个 App 不需要跟外部世界通信，所以 manifest 里连 INTERNET 权限都没有。
 */
public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "mathcoach/storage";
    private static final int REQ_PHOTO = 1001;
    private static final int REQ_PICK = 1002;
    private static final int REQ_DOC = 1003;

    /** 相机/相册是异步回结果的，Result 得先存着，等 onActivityResult 再还。 */
    private MethodChannel.Result pendingResult;
    private File pendingPhoto;

    @Override
    public void configureFlutterEngine(FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler(new MethodChannel.MethodCallHandler() {
                    @Override
                    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
                        if ("filesDir".equals(call.method)) {
                            result.success(dataDir());
                        } else if ("share".equals(call.method)) {
                            Object p = call.argument("path");
                            Object mime = call.argument("mime");
                            result.success(sharePaper(
                                    p == null ? null : p.toString(),
                                    mime == null ? null : mime.toString()));
                        } else if ("pickDocument".equals(call.method)) {
                            pendingResult = result;
                            if (!startDocPick()) {
                                pendingResult = null;
                                result.success(null);
                            }
                        } else if ("takePhoto".equals(call.method)) {
                            pendingResult = result;
                            if (!startCapture()) {
                                pendingResult = null;
                                result.success(null);
                            }
                        } else if ("pickImage".equals(call.method)) {
                            pendingResult = result;
                            if (!startPick()) {
                                pendingResult = null;
                                result.success(null);
                            }
                        } else if ("jpegBase64".equals(call.method)) {
                            Object p = call.argument("path");
                            Object mw = call.argument("maxWidth");
                            Object q = call.argument("quality");
                            result.success(jpegBase64(
                                    p == null ? null : p.toString(),
                                    mw instanceof Integer ? (Integer) mw : 1024,
                                    q instanceof Integer ? (Integer) q : 72));
                        } else {
                            result.notImplemented();
                        }
                    }
                });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        final MethodChannel.Result r = pendingResult;
        pendingResult = null;
        if (r == null) return;
        try {
            if (requestCode == REQ_PHOTO) {
                if (resultCode == RESULT_OK && pendingPhoto != null && pendingPhoto.exists()) {
                    r.success(pendingPhoto.getAbsolutePath());
                } else {
                    r.success(null); // 用户取消
                }
            } else if (requestCode == REQ_PICK) {
                if (resultCode == RESULT_OK && data != null && data.getData() != null) {
                    r.success(copyToApp(data.getData()));
                } else {
                    r.success(null);
                }
            } else if (requestCode == REQ_DOC) {
                if (resultCode == RESULT_OK && data != null && data.getData() != null) {
                    r.success(copyDocToApp(data.getData()));
                } else {
                    r.success(null); // 用户取消
                }
            }
        } catch (Exception e) {
            Log.e("MathCoach", "photo result failed", e);
            r.success(null);
        }
    }

    /**
     * 唤起系统相机拍一张。
     *
     * 走 ACTION_IMAGE_CAPTURE 而不是打包相机插件：省一个依赖，也省掉
     * 相机权限声明（用系统相机 App 拍照不需要本 App 声明 CAMERA 权限）。
     * 输出文件放在 App 专属目录，经 FileProvider 暴露给相机 App 写入。
     */
    private boolean startCapture() {
        try {
            pendingPhoto = newPhotoFile();
            if (pendingPhoto == null) return false;
            final Uri uri = FileProvider.getUriForFile(
                    this, getPackageName() + ".fileprovider", pendingPhoto);
            final Intent intent = new Intent(MediaStore.ACTION_IMAGE_CAPTURE);
            intent.putExtra(MediaStore.EXTRA_OUTPUT, uri);
            intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            startActivityForResult(intent, REQ_PHOTO);
            return true;
        } catch (Exception e) {
            Log.e("MathCoach", "startCapture failed", e);
            return false;
        }
    }

    private boolean startPick() {
        try {
            final Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.setType("image/*");
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            startActivityForResult(Intent.createChooser(intent, "选择题目照片"), REQ_PICK);
            return true;
        } catch (Exception e) {
            Log.e("MathCoach", "startPick failed", e);
            return false;
        }
    }

    /**
     * 挑一份备份 JSON。
     *
     * 同样是走系统选择器而不是申请存储权限：本 App 至今 0 权限，
     * 不能为了一个"导入"就把 READ_EXTERNAL_STORAGE 加回去。
     * 个别 ROM 的文档选择器不认 application/json，那就退到"全部文件"让用户自己挑，
     * 格式对不对交给 Dart 侧的 BackupCodec 去判（判错会给明确提示）。
     * （注释里千万别写星号加斜杠 —— 那会把这段块注释提前闭合掉，javac 会报莫名其妙的错。）
     */
    private boolean startDocPick() {
        try {
            final Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
            intent.setType("application/json");
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            try {
                startActivityForResult(Intent.createChooser(intent, "选择备份文件"), REQ_DOC);
            } catch (android.content.ActivityNotFoundException e) {
                intent.setType("*/*");
                startActivityForResult(Intent.createChooser(intent, "选择备份文件"), REQ_DOC);
            }
            return true;
        } catch (Exception e) {
            Log.e("MathCoach", "startDocPick failed", e);
            return false;
        }
    }

    /** 选中的是 content:// ，拷进 App 目录再交给 Dart 读（临时授权会失效）。 */
    private String copyDocToApp(Uri src) {
        File dir = new File(dataDir(), "backups");
        if (!dir.exists() && !dir.mkdirs()) return null;
        File out = new File(dir, "import_" + System.currentTimeMillis() + ".json");
        try {
            java.io.InputStream in = getContentResolver().openInputStream(src);
            if (in == null) return null;
            java.io.OutputStream os = new java.io.FileOutputStream(out);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            os.close();
            in.close();
            return out.getAbsolutePath();
        } catch (Exception e) {
            Log.e("MathCoach", "copy backup failed", e);
            return null;
        }
    }

    private File newPhotoFile() {
        File dir = new File(dataDir(), "photos");
        if (!dir.exists() && !dir.mkdirs()) return null;
        return new File(dir, "photo_" + System.currentTimeMillis() + ".jpg");
    }

    /**
     * 把照片压成小 JPEG，Dart 侧随后 base64 上传给识别模型。
     *
     * 为什么非得在原生做：dart:ui 只能编码 PNG，而 PNG 对照片是灾难 ——
     * 实测一张 1024px 的拍照风格图，PNG 1935 KB、JPEG(q72) 265 KB，差 7.3 倍。
     * 上传体积小一个量级，认题 / 认卷的等待时间跟着下来。
     * （家长 2026-10-17 反馈"拍照识题速度太慢了"，这是最大的一处。）
     *
     * RGB_565 而不是 ARGB_8888：省一半内存，黑白字不受影响。
     * 任何一步失败都返回 null，Dart 侧会退回它自己的 PNG 兜底 ——
     * 压图失败不该让整个拍照流程挂掉。
     */
    private String jpegBase64(String path, int maxWidth, int quality) {
        if (path == null || path.length() == 0) return null;
        try {
            final File f = new File(path);
            if (!f.exists()) return null;
            // 先只读边界算采样率（BitmapFactory 只认 2 的幂），再精确缩放
            final android.graphics.BitmapFactory.Options bounds =
                    new android.graphics.BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            android.graphics.BitmapFactory.decodeFile(path, bounds);
            final int bw = bounds.outWidth;
            final int bh = bounds.outHeight;
            if (bw <= 0 || bh <= 0) return null;
            int sample = 1;
            while (bw / (sample * 2) >= maxWidth && bh / (sample * 2) >= maxWidth) {
                sample *= 2;
            }
            final android.graphics.BitmapFactory.Options opts =
                    new android.graphics.BitmapFactory.Options();
            opts.inSampleSize = sample;
            opts.inPreferredConfig = android.graphics.Bitmap.Config.RGB_565;
            android.graphics.Bitmap bmp =
                    android.graphics.BitmapFactory.decodeFile(path, opts);
            if (bmp == null) return null;
            if (bmp.getWidth() > maxWidth) {
                final float scale = (float) maxWidth / bmp.getWidth();
                final android.graphics.Bitmap scaled = android.graphics.Bitmap.createScaledBitmap(
                        bmp, maxWidth, Math.max(1, Math.round(bmp.getHeight() * scale)), true);
                bmp.recycle();
                bmp = scaled;
            }
            final java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
            bmp.compress(android.graphics.Bitmap.CompressFormat.JPEG, quality, out);
            bmp.recycle();
            final byte[] bytes = out.toByteArray();
            out.close();
            return android.util.Base64.encodeToString(
                    bytes, android.util.Base64.NO_WRAP);
        } catch (Exception e) {
            Log.e("MathCoach", "jpegBase64 failed", e);
            return null;
        }
    }

    /** 相册返回的是 content:// ，拷进 App 目录才能稳定读（临时授权会失效）。 */
    private String copyToApp(Uri src) {
        File out = newPhotoFile();
        if (out == null) return null;
        try {
            java.io.InputStream in = getContentResolver().openInputStream(src);
            if (in == null) return null;
            java.io.OutputStream os = new java.io.FileOutputStream(out);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            os.close();
            in.close();
            return out.getAbsolutePath();
        } catch (Exception e) {
            Log.e("MathCoach", "copy image failed", e);
            return null;
        }
    }

    /**
     * 优先放外部专属目录：用户用手机自带「文件」App 就能找到，
     * 导出的练习卷可以直接拷出来打印。拿不到外部存储时退回内部目录。
     */
    private String dataDir() {
        File ext = getExternalFilesDir(null);
        File base = ext != null ? ext : getFilesDir();
        File dir = new File(base, "math_coach");
        if (!dir.exists() && !dir.mkdirs()) {
            return base.getAbsolutePath();
        }
        return dir.getAbsolutePath();
    }

    /**
     * 唤起系统分享面板。
     *
     * 用 chooser 而不是直接 startActivity：让用户自己决定发到微信还是
     * 打印服务，也避免被某个应用的默认行为劫持。
     * 任何一步失败都返回 false 而不是抛异常 —— 分享失败不该影响 App。
     */
    private boolean sharePaper(String path, String mime) {
        if (path == null || path.length() == 0) return false;
        try {
            final File f = new File(path);
            if (!f.exists()) {
                Log.e("MathCoach", "share: file not found " + path);
                return false;
            }
            final Uri uri = FileProvider.getUriForFile(
                    this, getPackageName() + ".fileprovider", f);
            final Intent intent = new Intent(Intent.ACTION_SEND);
            // 备份是 json：微信/邮件/网盘都收，别硬写成 pdf 让人打不开
            intent.setType(mime == null || mime.length() == 0 ? "application/pdf" : mime);
            intent.putExtra(Intent.EXTRA_STREAM, uri);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(intent, "发送练习卷"));
            return true;
        } catch (Exception e) {
            Log.e("MathCoach", "share failed", e);
            return false;
        }
    }
}
