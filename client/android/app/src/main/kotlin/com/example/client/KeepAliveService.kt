package com.example.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/// Servicio en primer plano: mantiene vivo el proceso de la app (y con él el WebSocket con
/// el servidor y las descargas) cuando se minimiza o se apaga la pantalla.
///
/// Android obliga a que un servicio así tenga una notificación. Se deja en un canal de
/// importancia mínima (sin sonido ni icono en la barra de estado, oculta en la pantalla de
/// bloqueo). Mientras hay descargas, esa misma notificación pasa a mostrar su progreso.
/// Además, aquí viven los avisos puntuales (descarga terminada, petición disponible).
class KeepAliveService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannels(this)
        val n = lastProgress ?: quietNotification(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, n)
        }
        running = true
        acquireLocks()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        lastProgress = null
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        try {
            if (wake == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lumen:keepalive")
                    .apply { setReferenceCounted(false) }
            }
            if (wake?.isHeld != true) wake?.acquire()
        } catch (_: Exception) {}
        try {
            if (wifi == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= 29)
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifi = wm.createWifiLock(mode, "lumen:keepalive").apply { setReferenceCounted(false) }
            }
            if (wifi?.isHeld != true) wifi?.acquire()
        } catch (_: Exception) {}
    }

    private fun releaseLocks() {
        try { if (wake?.isHeld == true) wake?.release() } catch (_: Exception) {}
        try { if (wifi?.isHeld == true) wifi?.release() } catch (_: Exception) {}
        wake = null
        wifi = null
    }

    companion object {
        const val CH_BG = "lumen_bg"
        const val CH_DOWNLOADS = "lumen_downloads"
        const val CH_EVENTS = "lumen_events"
        const val NOTIF_ID = 4101

        @Volatile private var running = false
        @Volatile private var lastProgress: Notification? = null

        private fun nm(ctx: Context) =
            ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        fun ensureChannels(ctx: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val m = nm(ctx)
            // Canal antiguo ("Conectado al servidor"): se retira.
            try { m.deleteNotificationChannel("lumen_keepalive") } catch (_: Exception) {}
            if (m.getNotificationChannel(CH_BG) == null) {
                val c = NotificationChannel(CH_BG, "Segundo plano", NotificationManager.IMPORTANCE_MIN)
                c.description = "Necesaria para que la app siga conectada con la pantalla apagada. " +
                    "Puedes silenciarla u ocultarla sin que deje de funcionar."
                c.setShowBadge(false)
                c.lockscreenVisibility = Notification.VISIBILITY_SECRET
                m.createNotificationChannel(c)
            }
            if (m.getNotificationChannel(CH_DOWNLOADS) == null) {
                val c = NotificationChannel(CH_DOWNLOADS, "Descargas", NotificationManager.IMPORTANCE_LOW)
                c.description = "Progreso de las descargas en curso."
                c.setShowBadge(false)
                m.createNotificationChannel(c)
            }
            if (m.getNotificationChannel(CH_EVENTS) == null) {
                val c = NotificationChannel(CH_EVENTS, "Avisos", NotificationManager.IMPORTANCE_HIGH)
                c.description = "Descargas terminadas y películas que pediste ya disponibles."
                m.createNotificationChannel(c)
            }
        }

        private fun openApp(ctx: Context, req: Int): PendingIntent? {
            val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return null
            return PendingIntent.getActivity(ctx, req, open,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        private fun builder(ctx: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, channel)
            else @Suppress("DEPRECATION") Notification.Builder(ctx)

        /// La notificación obligatoria del servicio cuando no hay nada que contar.
        fun quietNotification(ctx: Context): Notification =
            builder(ctx, CH_BG)
                .setContentTitle("Lumen")
                .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
                .setContentIntent(openApp(ctx, 0))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setVisibility(Notification.VISIBILITY_SECRET)
                .apply { if (Build.VERSION.SDK_INT < 26) setPriority(Notification.PRIORITY_MIN) }
                .build()

        /// Muestra el progreso de las descargas en la notificación del servicio.
        /// [percent] < 0 = sin porcentaje conocido.
        fun showProgress(ctx: Context, title: String, text: String, percent: Int) {
            val app = ctx.applicationContext
            ensureChannels(app)
            val b = builder(app, CH_DOWNLOADS)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentIntent(openApp(app, 0))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setProgress(100, percent.coerceIn(0, 100), percent < 0)
            val n = b.build()
            lastProgress = n
            try { nm(app).notify(NOTIF_ID, n) } catch (_: Exception) {}
        }

        /// Vuelve a la notificación discreta del servicio (o la retira si no está activo).
        fun clearProgress(ctx: Context) {
            val app = ctx.applicationContext
            lastProgress = null
            try {
                if (running) nm(app).notify(NOTIF_ID, quietNotification(app))
                else nm(app).cancel(NOTIF_ID)
            } catch (_: Exception) {}
        }

        /// Aviso puntual (con sonido): descarga terminada, petición disponible...
        fun notifyEvent(ctx: Context, id: Int, title: String, text: String) {
            val app = ctx.applicationContext
            ensureChannels(app)
            val n = builder(app, CH_EVENTS)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentIntent(openApp(app, id))
                .setAutoCancel(true)
                .build()
            try { nm(app).notify(id, n) } catch (_: Exception) {}
        }
    }
}
