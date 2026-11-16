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

    // edge-to-edge 之后系统不再替我们压缩布局：键盘只是盖在 WebView 上，
    // 用户看不到自己正在输入什么。这里只把「键盘那一截」让出来，
    // 其余 insets 原样传下去（状态栏、刘海仍由 WebView 与 CSS 安全区处理）。
    val content = findViewById<View>(android.R.id.content)
    ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
      val ime = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
      if (view.paddingBottom != ime) {
        view.setPadding(view.paddingLeft, view.paddingTop, view.paddingRight, ime)
      }
      insets
    }
  }
}
