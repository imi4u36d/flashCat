package dev.flashcat.desktop

import android.os.Bundle
import android.view.View
import androidx.activity.enableEdgeToEdge
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

class MainActivity : TauriActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)

    // edge-to-edge 之后系统不再替我们压缩布局：
    // - 键盘盖在 WebView 上 → 用户看不见自己在输入什么；
    // - 手势条盖在底部标签栏上 → 「概览 / 模型」的字被那条横线压住。
    // 这两件事都靠底部 inset 解决，取两者较大值，其余 insets 原样传下去。
    val content = findViewById<View>(android.R.id.content)
    ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
      val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
      val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
      val bottom = maxOf(bars, ime)
      if (view.paddingBottom != bottom) {
        view.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, bottom)
      }
      insets
    }
  }
}
