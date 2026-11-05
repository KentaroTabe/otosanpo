package dev.otosanpo

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * 画面を素の View で組むための小道具。
 *
 * **外部の UI ライブラリも res/ の資産も足さない**(docs/10)。
 * 画面が 3 つ(主画面・メニュー・ログ)に分かれたので、
 * 同じ見た目を 3 箇所へ書き写さないようここへ出した(2026-09-19)。
 */

/** 節の見出し */
fun Context.heading(t: String) = TextView(this).apply {
    text = t
    setTypeface(typeface, Typeface.BOLD)
    setPadding(0, 40, 0, 8)
}

/** 本文 */
fun Context.label(t: String) = TextView(this).apply {
    text = t
    setPadding(0, 4, 0, 4)
}

/** 補足(小さめ)。設定の意味を添えるのに使う */
fun Context.caption(t: String) = TextView(this).apply {
    text = t
    textSize = 12f
    setPadding(0, 0, 0, 8)
}

fun Context.button(t: String, action: () -> Unit) = Button(this).apply {
    text = t
    setOnClickListener { action() }
}

/** 画面の土台(縦並び + 余白) */
fun Context.column() = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(32, 32, 32, 32)
}

fun Context.row() = LinearLayout(this).apply {
    orientation = LinearLayout.HORIZONTAL
}

/**
 * 縦に伸びる画面を巻物に入れ、**システムバーの下に潜り込まないよう余白を当てる**。
 *
 * ## なぜ余白が要るか(2026-09-19 にエミュレータで実測)
 *
 * `targetSdk 35` のアプリは **Android 15 から端から端まで描く**のが既定になった。
 * 素の Activity では内容が窓の y=0 から並ぶので、**状態バーと上の帯が内容を覆う**。
 *
 * 実測では `ScrollView` の bounds が `[0,0][1080,2400]` になり、
 * 「設定」(y 32–134)と「自宅: 未設定」(134–196)が完全に隠れ、
 * **テスターが最初に押す「自宅を現在地に設定」が 40px しか見えていなかった。**
 *
 * `res/` にテーマを足せば `windowOptOutEdgeToEdgeEnforcement` で降りられるが、
 * **素の View だけで組む構成を崩さない**ため、差し込まれた余白を自分で当てる。
 */
fun Activity.scrolling(content: View) = ScrollView(this).apply {
    addView(content, ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT)
    // **上の帯のぶんを自分で足さない。** 内容へ配られる余白には既に帯の高さが入っている
    // (2026-09-19 実測: 275px = 状態バー 132 + 帯 147)。足すと二重になり、
    // 帯と「設定」の間が 150px ほど空いた
    setOnApplyWindowInsetsListener { v, insets ->
        val top: Int
        val bottom: Int
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            top = bars.top
            bottom = bars.bottom
        } else {
            @Suppress("DEPRECATION")
            top = insets.systemWindowInsetTop
            @Suppress("DEPRECATION")
            bottom = insets.systemWindowInsetBottom
        }
        v.setPadding(v.paddingLeft, top, v.paddingRight, bottom)
        insets
    }
    requestApplyInsets()
}

/**
 * 左上のメニューを開く三本線(2026-09-19 利用者依頼)。
 *
 * > 「毎回設定するわけではないものを格納しておくため左上にいわゆる
 * > ハンバーガー(よこせん3本のメニューバー)を作り」
 *
 * 枠組みの drawable にハンバーガーは無いので、**四角を 3 つ重ねて描く**。
 * 画像を足すと res/ を持つことになり、「素の View だけ」の構成が崩れる。
 */
fun Activity.menuIcon(): Drawable {
    val d = resources.displayMetrics.density
    fun px(dp: Double) = (dp * d).toFloat()
    val box = px(24.0).toInt()  // 枠(Android の標準的な操作アイコンの大きさ)
    val thick = px(2.0)         // 線の太さ
    val side = px(3.0)          // 左右の余白

    val value = TypedValue()
    theme.resolveAttribute(android.R.attr.colorForeground, value, true)
    val fg = if (value.type >= TypedValue.TYPE_FIRST_COLOR_INT &&
                 value.type <= TypedValue.TYPE_LAST_COLOR_INT) value.data else Color.BLACK

    // **Canvas で直に描く。** `LayerDrawable` + `setLayerInset` で組んだ版は
    // **黒い四角になった**(2026-09-19 にエミュレータで実測)。inset は子の固有サイズに
    // **加算**されるので、枠が 24dp を超えて広がり、3 本が太って潰れていた。
    // 絵を焼いてしまえば、枠の大きさも線の位置も見たとおりになる
    val bitmap = Bitmap.createBitmap(box, box, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = fg }
    for (top in listOf(px(5.0), px(11.0), px(17.0))) {
        canvas.drawRect(side, top, box - side, top + thick, paint)
    }
    return BitmapDrawable(resources, bitmap)
}

/**
 * 左上に三本線を出す。押された時の処理は各画面の `onOptionsItemSelected` で
 * `android.R.id.home` を見て書く。
 *
 * @return 出せたか。**端末の組み合わせによっては上の帯そのものが無い**ので、
 *   出せなかった時は呼ぶ側が画面の中に導線を置く(メニューへ行けないと
 *   ログも試聴も取り出せなくなる)
 */
fun Activity.installMenuButton(): Boolean {
    val bar = actionBar ?: return false
    bar.setHomeAsUpIndicator(menuIcon())
    bar.setDisplayHomeAsUpEnabled(true)
    return true
}

/** 戻る矢印(メニューやログの画面)。三本線は主画面だけに出す */
fun Activity.installBackButton() {
    actionBar?.setDisplayHomeAsUpEnabled(true)
}
