package com.mathcoach.app;

import android.app.Application;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * 崩溃自报。
 *
 * 这个 App 走的是手工构建的 APK 链路，没有 CI，也没有真机调试台 ——
 * 用户在红米上点开图标直接闪退时，我这边拿不到任何 logcat。
 * 所以把最后一道防线做进 App 自己：
 *
 *   1. 装一个 UncaughtExceptionHandler，把完整堆栈写进 crash.txt
 *   2. 顺手塞进剪贴板 —— 用户不需要 root、不需要连电脑，长按粘贴就能把堆栈发出来
 *   3. 下次启动时 Toast 提示"上次崩了"，并把堆栈再复制一次
 *
 * 崩溃发生在主线程时 Toast 往往来不及显示，所以 3 是主要出口，2 是兜底。
 */
public class MainApplication extends Application {

    private static final String TAG = "MathCoach";
    static final String CRASH_FILE = "crash.txt";

    @Override
    public void onCreate() {
        super.onCreate();
        install(this);
        announcePreviousCrash(this);
    }

    static File crashFile(Context ctx) {
        File base = ctx.getExternalFilesDir(null);
        if (base == null) {
            base = ctx.getFilesDir();
        }
        File dir = new File(base, "math_coach");
        if (!dir.exists()) {
            dir.mkdirs();
        }
        return new File(dir, CRASH_FILE);
    }

    private static void install(Context ctx) {
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override
            public void uncaughtException(Thread t, Throwable e) {
                try {
                    StringWriter sw = new StringWriter();
                    PrintWriter pw = new PrintWriter(sw);
                    pw.println("device: " + android.os.Build.MANUFACTURER + " "
                            + android.os.Build.MODEL + " / Android "
                            + android.os.Build.VERSION.SDK_INT);
                    pw.println("time:   " + new SimpleDateFormat(
                            "yyyy-MM-dd HH:mm:ss", Locale.CHINA).format(new Date()));
                    pw.println("thread: " + t.getName());
                    pw.println("abi:    " + android.os.Build.SUPPORTED_ABIS[0]);
                    pw.println();
                    e.printStackTrace(pw);
                    pw.println("\n--- cause ---");
                    Throwable c = e.getCause();
                    while (c != null) {
                        c.printStackTrace(pw);
                        c = c.getCause();
                    }
                    String text = sw.toString();

                    File f = crashFile(ctx);
                    FileOutputStream out = new FileOutputStream(f, false);
                    out.write(text.getBytes("UTF-8"));
                    out.close();
                    Log.e(TAG, "crash saved to " + f.getAbsolutePath() + "\n" + text);

                    copyToClipboard(ctx, text);
                } catch (Throwable ignored) {
                    // 崩溃处理自己再抛异常只会把现场抹掉，静默吞掉
                }
                android.os.Process.killProcess(android.os.Process.myPid());
                System.exit(10);
            }
        });
    }

    private static void copyToClipboard(Context ctx, String text) {
        ClipboardManager cm = (ClipboardManager) ctx.getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm == null) {
            return;
        }
        // 剪贴板放不下就只放头部和尾部：头上有异常类型，尾上有最先出错的那一行
        String clip = text.length() > 6000
                ? text.substring(0, 3000) + "\n...\n" + text.substring(text.length() - 3000)
                : text;
        cm.setPrimaryClip(ClipData.newPlainText("mathcoach-crash", clip));
    }

    /** 上次崩过就吱一声 —— 崩溃当下的 Toast 基本来不及渲染，靠这次补上。 */
    private static void announcePreviousCrash(Context ctx) {
        final File f = crashFile(ctx);
        if (!f.exists()) {
            return;
        }
        String text;
        try {
            byte[] buf = new byte[(int) f.length()];
            java.io.FileInputStream in = new java.io.FileInputStream(f);
            in.read(buf);
            in.close();
            text = new String(buf, "UTF-8");
        } catch (Throwable ignored) {
            return;
        }
        copyToClipboard(ctx, text);

        String first = text;
        int nl = text.indexOf('\n');
        String head = nl > 0 ? text.substring(0, Math.min(nl, 200)) : text.substring(0, Math.min(text.length(), 200));
        final String msg = "上次崩溃已记录（堆栈已复制，可粘贴给我）：" + head;
        new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(ctx, msg, Toast.LENGTH_LONG).show();
            }
        }, 1200);
        // 提示过一次就够了，免得每次开局都弹
        f.renameTo(new File(f.getParentFile(), "crash-shown.txt"));
    }
}
