package app.zemote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlin.math.roundToInt

/**
 * Keeps the process + relay alive while the app is backgrounded and shows the
 * ongoing "running tasks" notification. Content is updated via
 * [update] whenever the monitor publishes a new snapshot.
 *
 * On Android 16+ (ColorOS 16 流体云 / promoted ongoing) the notification is
 * built as a Live Update: `setRequestPromotedOngoing` + `ProgressStyle`, so
 * the system promotes it to the status chip / lock screen / drawer top.
 * [progress] (0..1) drives the ProgressStyle bar; null renders an activity
 * bar (indeterminate).
 */
class ZemoteNotificationService : Service() {
    companion object {
        const val CHANNEL_RUNNING = "running_tasks"
        const val NOTIFICATION_ID = 1001

        // Hex literals above Int.MAX are Long in Kotlin; .toInt() needs a
        // plain val (const val forbids function calls).
        private val COLOR_DONE = 0xFF3B82F6.toInt()

        @Volatile
        var instance: ZemoteNotificationService? = null
            private set

        fun start(context: Context, title: String, text: String, progress: Double?) {
            val intent = Intent(context, ZemoteNotificationService::class.java)
                .putExtra("title", title)
                .putExtra("text", text)
            if (progress != null) intent.putExtra("progress", progress)
            context.startForegroundService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createChannels()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance === this) instance = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "任务运行中"
        val text = intent?.getStringExtra("text") ?: ""
        val progress =
            if (intent?.hasExtra("progress") == true) intent.getDoubleExtra("progress", 0.0)
            else null
        startForeground(NOTIFICATION_ID, buildNotification(title, text, progress))
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Update the ongoing notification in place (no re-alert). */
    fun update(title: String, text: String, progress: Double?) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(title, text, progress))
    }

    private fun createChannels() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_RUNNING,
                "运行中的任务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "后台运行时展示正在执行的任务及最新进展"
                setSound(null, null)
                enableVibration(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(
                TaskNotifications.CHANNEL_COMPLETED,
                "任务完成",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "任务完成时静默提醒（不弹窗）"
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    private fun tapPendingIntent(): PendingIntent {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(
            this,
            0,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildNotification(title: String, text: String, progress: Double?): Notification {
        // androidx compat: ProgressStyle renders natively on Android 16+ (and
        // gets promoted when the user allows it); older systems degrade to a
        // plain ongoing notification. setRequestPromotedOngoing is a compat
        // extra — no framework symbol required to compile.
        val style = NotificationCompat.ProgressStyle()
        if (progress != null) {
            // Compat ProgressStyle max defaults to 100 (getProgressMax()).
            val done = (progress * 100).roundToInt().coerceIn(0, 100)
            style.addProgressSegment(
                NotificationCompat.ProgressStyle.Segment(100).setColor(COLOR_DONE)
            ).setProgress(done)
        } else {
            style.setProgressIndeterminate(true)
        }
        return NotificationCompat.Builder(this, CHANNEL_RUNNING)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(style)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(tapPendingIntent())
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setRequestPromotedOngoing(true)
            .build()
    }
}

/** Silently fires dismissible "task completed" notifications. */
object TaskNotifications {
    const val CHANNEL_COMPLETED = "task_completed"
    private var nextId = 2001

    /** [payload] is a JSON string the Dart side uses to deep-link into chat. */
    fun notify(context: Context, title: String, text: String, payload: String?) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_COMPLETED,
                "任务完成",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setSound(null, null)
                enableVibration(false)
            }
        )
        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (payload != null) putExtra("notificationTask", payload)
        }
        val pending = PendingIntent.getActivity(
            context,
            nextId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_COMPLETED)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setContentIntent(pending)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        nm.notify(nextId, notification)
        nextId += 1
    }
}
