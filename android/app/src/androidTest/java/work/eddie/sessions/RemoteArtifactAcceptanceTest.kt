package work.eddie.sessions

import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** Explicit read-only device acceptance. Does not send a message or alter a task. */
class RemoteArtifactAcceptanceTest{
 @Test fun pairedPhoneDownloadsRegisteredMiniFileAndProvidesShareUri()=runBlocking{
  val args=InstrumentationRegistry.getArguments()
  val id=args.getString("artifactId")?:return@runBlocking
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  val store=Store(context)
  val item=store.request("/personal/artifacts").array("items").first{it.optString("id")==id}
  val file=store.downloadArtifact(id,item.optString("name"))
  assertTrue(file.exists());assertEquals(item.optLong("size"),file.length())
  val uri=FileProvider.getUriForFile(context,context.packageName+".artifacts",file)
  assertEquals("content",uri.scheme)
  context.contentResolver.openInputStream(uri)!!.use{assertTrue(it.read()!=-1)}
  if(file.extension=="pdf")PdfRenderer(ParcelFileDescriptor.open(file,ParcelFileDescriptor.MODE_READ_ONLY)).use{assertTrue(it.pageCount>0)}
  println("REMOTE_ARTIFACT_OK name=${file.name} bytes=${file.length()} content_uri=${uri.scheme}")
 }
}
