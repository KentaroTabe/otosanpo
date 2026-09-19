package dev.otosanpo

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.ShapeDrawable
import android.graphics.drawable.shapes.RectShape
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
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

/** 縦に伸びる画面を巻物に入れる */
fun Context.scrolling(content: View) = ScrollView(this).apply {
    addView(content, ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT)
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
    fun px(dp: Double) = (dp * d).toInt()
    val box = px(24.0)          // 枠の当たり(Android の標準的な操作アイコンの大きさ)
    val thick = px(2.0)         // 線の太さ
    val side = px(3.0)          // 左右の余白
    val tops = listOf(px(4.0), px(11.0), px(18.0))

    val value = TypedValue()
    theme.resolveAttribute(android.R.attr.colorForeground, value, true)
    val fg = if (value.type >= TypedValue.TYPE_FIRST_COLOR_INT &&
                 value.type <= TypedValue.TYPE_LAST_COLOR_INT) value.data else Color.BLACK

    val bars = Array<Drawable>(tops.size) {
        ShapeDrawable(RectShape()).apply {
            paint.color = fg
            // LayerDrawable の大きさは子から決まる。3 本とも枠いっぱいに取り、
            // inset で線の位置を作る
            intrinsicWidth = box
            intrinsicHeight = box
        }
    }
    return LayerDrawable(bars).apply {
        tops.forEachIndexed { i, top -> setLayerInset(i, side, top, side, box - top - thick) }
    }
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
