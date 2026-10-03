package work.eddie.sessions

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable fun ArtifactPreview(file:File,dismiss:()->Unit){
 var page by remember(file){mutableIntStateOf(0)}
 var pageCount by remember(file){mutableIntStateOf(1)}
 var bitmap by remember(file){mutableStateOf<Bitmap?>(null)}
 var text by remember(file){mutableStateOf("")}
 var error by remember(file){mutableStateOf("")}
 LaunchedEffect(file,page){
  try{withContext(Dispatchers.IO){
   when(file.extension.lowercase()){
    "pdf"->PdfRenderer(ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY)).use{pdf->
     pageCount=pdf.pageCount
     pdf.openPage(page).use{p->
      val width=1200;val height=(width.toDouble()*p.height/p.width).toInt().coerceIn(1,4000)
      val result=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);result.eraseColor(android.graphics.Color.WHITE)
      p.render(result,null,null,PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);bitmap=result
     }
    }
    "md","txt","csv"->{text=file.inputStream().bufferedReader().use{reader->val chars=CharArray(200000);val count=reader.read(chars);if(count>0)String(chars,0,count) else ""}}
    else->{val bounds=BitmapFactory.Options().apply{inJustDecodeBounds=true};BitmapFactory.decodeFile(file.path,bounds)
     val options=BitmapFactory.Options().apply{var sample=1;while(maxOf(bounds.outWidth,bounds.outHeight)/sample>1600)sample*=2;inSampleSize=sample}
     bitmap=BitmapFactory.decodeFile(file.path,options);if(bitmap==null)error("图片无法解码")}
   }
  }}catch(e:Exception){error=e.message?:"预览暂不可用"}
 }
 AlertDialog(onDismissRequest=dismiss,containerColor=Card,title={Text(file.name)},text={Column(Modifier.fillMaxWidth().heightIn(max=500.dp).verticalScroll(rememberScrollState())){
  if(error.isNotBlank())Text(error,color=AmberText)
  bitmap?.let{Image(it.asImageBitmap(),file.name,Modifier.fillMaxWidth())}
  if(text.isNotBlank())SelectionContainer{Text(text,fontSize=Type.BodySm,color=Ink)}
  if(pageCount>1)Row{TextButton(onClick={page--},enabled=page>0){Text("上一页")};Text("${page+1}/$pageCount");TextButton(onClick={page++},enabled=page+1<pageCount){Text("下一页")}}
 }},confirmButton={TextButton(onClick=dismiss){Text("关闭")}})
}
