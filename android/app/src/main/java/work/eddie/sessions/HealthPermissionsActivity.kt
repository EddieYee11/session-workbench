package work.eddie.sessions

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

class HealthPermissionsActivity:ComponentActivity(){
 override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState)
  setContent{MaterialTheme(colorScheme=Palette,typography=ComTypography,shapes=ComShapes){Surface(color=Paper){Column(Modifier.fillMaxSize().statusBarsPadding().padding(24.dp),verticalArrangement=Arrangement.spacedBy(20.dp)){
   RoundIcon(Icons.Outlined.ArrowBack,"返回"){finish()}
   Text("健康数据与隐私",fontSize=Type.AppTitle)
   Text("Com! 在你授权后读取步数和心率，用于个人健康分析和简报。后台及历史记录只在系统提供相应权限时读取。")
   Text("数据通过已配对连接传到你的 Mac mini，保留来源、覆盖时间和缺失原因。健康原始记录独立保存，不自动成为永久个人画像。")
   Text("你可以在 Health Connect 随时撤销权限，也可以在 Com! 的手机节点设置中关闭连接。未授权或无记录时会明确显示缺失。",color=Muted)
  }}}}
 }
}
