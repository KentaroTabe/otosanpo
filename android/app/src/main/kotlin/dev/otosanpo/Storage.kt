package dev.otosanpo

import android.content.Context
import dev.otosanpo.core.AppParameters
import dev.otosanpo.core.GeoPoint
import dev.otosanpo.core.SpeedEstimator
import dev.otosanpo.core.VisitGrid
import dev.otosanpo.core.WalkGraph
import dev.otosanpo.core.WalkMap
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 端末内の保存。**すべて端末内で完結し、送信しない**(docs/04)。
 *
 * 地図とフィールドログは `getExternalFilesDir`(= Android/data/dev.otosanpo/files)に置く。
 * USB でもファイル管理アプリでも出し入れできるので、iOS の「ファイル」アプリに相当する。
 *
 * **保存形式は素のテキスト。** JSON の仕組みは Core が持っているが、ここで扱うのは
 * 自宅の 1 点・速度の 2 値・セルの一覧だけなので、行区切りで足りる。
 * 依存を足さないぶん、他人の環境でビルドが通らない可能性が減る。
 */
class Storage(private val context: Context) {

    /** 出し入れするファイルの置き場(利用者から見える) */
    val sharedDir: File? get() = context.getExternalFilesDir(null)

    // MARK: - 設定

    /**
     * `config/parameters.json` を assets から読む。**iOS 版と同じファイル**を
     * ビルド時にコピーしている(app/build.gradle.kts)。
     * **フォールバック値は持たない。** 読めなければ例外を上げて止める(CLAUDE.md)
     */
    fun loadParameters(): AppParameters =
        context.assets.open("parameters.json").use {
            AppParameters.decode(it.readBytes().decodeToString())
        }

    // MARK: - 経路データ

    /**
     * 経路データ。無ければ null(グリッドのみで動く)。
     *
     * 探す順は **端末に置かれたファイル → APK に同梱したもの**。
     *
     * 同梱を足したのは、**テスターが `Android/data/dev.otosanpo/files/` へ
     * ファイルを置けなかった**ため(2026-08-28)。この場所は Android 11 以降、
     * 標準のファイルアプリから辿りにくく、機種によっては見えない。
     * 相手の都市が分かっているなら、ビルド時に入れてしまうほうが確実
     * (`scripts/build_android.sh <都市名>`)。
     *
     * **置かれたファイルを優先する。** 同梱は「置けなかった人のための既定値」であって、
     * 自分で用意した人の地図を上書きしてはいけない。
     */
    fun loadGraph(cellSizeM: Double): WalkGraph? =
        decodeGraph(cellSizeM, externalMapText()) ?: decodeGraph(cellSizeM, bundledMapText())

    /** 端末に置かれた経路データ。PC 側の `scripts/build_map.sh` が作った JSON */
    private fun externalMapText(): String? {
        val f = File(sharedDir, MAP_FILE)
        return if (f.exists()) runCatching { f.readText() }.getOrNull() else null
    }

    /** APK に同梱した経路データ。同梱していなければ無い */
    private fun bundledMapText(): String? =
        runCatching { context.assets.open(MAP_FILE).use { it.readBytes().decodeToString() } }
            .getOrNull()

    private fun decodeGraph(cellSizeM: Double, text: String?): WalkGraph? {
        if (text == null) return null
        return runCatching { WalkGraph(WalkMap.decode(text), cellSizeM) }.getOrNull()
    }

    // MARK: - 自宅

    fun loadHome(): GeoPoint? {
        val lat = prefs.getString("home_lat", null)?.toDoubleOrNull() ?: return null
        val lon = prefs.getString("home_lon", null)?.toDoubleOrNull() ?: return null
        return GeoPoint(lat, lon)
    }

    fun saveHome(p: GeoPoint) {
        prefs.edit()
            .putString("home_lat", p.latitude.toString())
            .putString("home_lon", p.longitude.toString())
            .apply()
    }

    // MARK: - 通過履歴

    /** 1 行 1 セル: `ix\tiy\tcount\todometer\texcluded` */
    fun loadGrid(cellSizeM: Double, halfLifeM: Double): VisitGrid {
        val grid = VisitGrid(cellSizeM, halfLifeM)
        val f = File(context.filesDir, GRID_FILE)
        if (!f.exists()) return grid
        try {
            var odometer = 0.0
            val entries = mutableListOf<VisitGrid.CellRecordEntry>()
            for (line in f.readLines()) {
                if (line.startsWith("#")) {
                    odometer = line.removePrefix("#").trim().toDoubleOrNull() ?: 0.0
                    continue
                }
                val c = line.split("\t")
                if (c.size < 5) continue
                entries.add(
                    VisitGrid.CellRecordEntry(
                        ix = c[0].toInt(), iy = c[1].toInt(),
                        count = c[2].toDouble(), lastOdometerM = c[3].toDouble(),
                        excluded = c[4] == "1"
                    )
                )
            }
            grid.restore(entries, odometer)
        } catch (e: Exception) {
            // 壊れていたら捨てる。履歴は作り直せる
        }
        return grid
    }

    fun saveGrid(grid: VisitGrid) {
        try {
            val text = buildString {
                append("#").append(grid.odometerM).append("\n")
                for (e in grid.entries()) {
                    append(e.ix).append("\t").append(e.iy).append("\t")
                        .append(e.count).append("\t").append(e.lastOdometerM).append("\t")
                        .append(if (e.excluded) "1" else "0").append("\n")
                }
            }
            File(context.filesDir, GRID_FILE).writeText(text)
        } catch (e: Exception) {
        }
    }

    // MARK: - 歩行速度の推定

    fun loadSpeed(): SpeedEstimator =
        SpeedEstimator(
            mPerMin = prefs.getString("speed_m_per_min", null)?.toDoubleOrNull(),
            walks = prefs.getInt("speed_walks", 0)
        )

    fun saveSpeed(e: SpeedEstimator) {
        prefs.edit()
            .putString("speed_m_per_min", e.mPerMin?.toString())
            .putInt("speed_walks", e.walks)
            .apply()
    }

    // MARK: - フィールドログ

    val fieldLog: File get() = File(sharedDir, LOG_FILE)

    /** TSV: 時刻 / 状態 / 緯度 / 経度 / メッセージ(iOS 版と同じ形式) */
    fun appendLog(state: String, position: GeoPoint?, message: String) {
        val f = fieldLog
        try {
            if (!f.exists()) f.writeText("time\tstate\tlat\tlon\tmessage\n")
            val line = listOf(
                isoFormatter.format(Date()),
                state,
                position?.let { "%.6f".format(it.latitude) } ?: "",
                position?.let { "%.6f".format(it.longitude) } ?: "",
                message.replace("\t", " ")
            ).joinToString("\t") + "\n"
            f.appendText(line)
        } catch (e: Exception) {
            // 記録できなくても散歩は続ける
        }
    }

    fun clearLog() {
        try { fieldLog.delete() } catch (e: Exception) {}
    }

    /**
     * ログを「ダウンロード」へ複製する。**テスターが感想と一緒に返せるようにするため。**
     *
     * アプリの置き場(`Android/data/...`)は Android 11 以降、他のアプリから開けない。
     * PC に USB で繋げば取り出せるが、それを頼むのは重い。`MediaStore` 経由で
     * ダウンロードに置けば、標準のファイルアプリから共有できる。
     *
     * @return 置いたファイル名。失敗したら null
     */
    fun exportLogToDownloads(): String? {
        val src = fieldLog
        if (!src.exists()) return null
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val name = "otosanpo-field-log-$stamp.tsv"
        return try {
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.Downloads.DISPLAY_NAME, name)
                put(android.provider.MediaStore.Downloads.MIME_TYPE, "text/tab-separated-values")
            }
            val uri = context.contentResolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
            ) ?: return null
            context.contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { it.copyTo(out) }
            }
            name
        } catch (e: Exception) {
            null
        }
    }

    private val prefs = context.getSharedPreferences("otosanpo", Context.MODE_PRIVATE)

    private val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US)

    companion object {
        const val MAP_FILE = "otosanpo-map.json"
        const val LOG_FILE = "otosanpo-field-log.tsv"
        private const val GRID_FILE = "visit_grid.tsv"
    }
}
