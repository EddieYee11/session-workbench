package work.eddie.sessions

/** 语音记账解析：从转写文本里提取金额 / 分类 / 备注 */

data class ParsedExpense(val amount:Double?,val category:String,val note:String)

private val digitMap=mapOf('零' to 0,'一' to 1,'二' to 2,'三' to 3,'四' to 4,'五' to 5,'六' to 6,'七' to 7,'八' to 8,'九' to 9,'两' to 2)

private fun chineseNumberToDouble(s:String):Double?{
 if(s.isEmpty())return null
 var total=0.0;var current=0.0;var hasDigit=false;var i=0
 while(i<s.length){
  val c=s[i]
  when{
   c in digitMap->{current=current*10+digitMap[c]!!;hasDigit=true;i++}
   c=='十'->{val v=if(!hasDigit&&current==0.0)1.0 else current;total+=v*10;current=0.0;hasDigit=false;i++}
   c=='百'->{val v=if(!hasDigit&&current==0.0)1.0 else current;total+=v*100;current=0.0;hasDigit=false;i++}
   c=='千'->{val v=if(!hasDigit&&current==0.0)1.0 else current;total+=v*1000;current=0.0;hasDigit=false;i++}
   c=='万'->{total=(total+current)*10000;current=0.0;hasDigit=false;i++}
   else->return null
  }
 }
 total+=current
 return if(hasDigit||total>0)total else null
}

private fun tokenToDouble(token:String):Double?{
 if(token.isEmpty())return null
 return if(token.any{it.isDigit()})token.toDoubleOrNull() else chineseNumberToDouble(token)
}

private fun guessCategory(text:String):String{
 val table=listOf(
  "餐饮" to listOf("早餐","午餐","晚餐","午饭","晚饭","夜宵","外卖","吃饭","喝","咖啡","奶茶","餐厅","食堂","火锅","烧烤","买菜","水果","零食","聚餐"),
  "交通" to listOf("打车","车费","地铁","公交","加油","停车","高速","机票","火车","滴滴","单车","过路费"),
  "购物" to listOf("买","购物","衣服","鞋","超市","淘宝","京东","拼多多","快递","日用"),
  "生活" to listOf("话费","水电","房租","物业","理发","药","医院","看病","体检"),
  "娱乐" to listOf("电影","游戏","旅游","酒店","门票","KTV","演出","展览"),
 )
 for((cat,words) in table)if(words.any{text.contains(it)})return cat
 return "其他"
}

/** 例：“午饭三十五”→35/餐饮/午饭；“打车 48.5 元”→48.5/交通/打车 */
fun parseExpense(transcript:String):ParsedExpense{
 val text=transcript.trim()
 // 优先找带单位的金额（最强信号），其次找阿拉伯数字
 val withUnit=Regex("([0-9]+(?:\\.[0-9]{1,2})?|[零一二三四五六七八九两十百千万]+)\\s*(元|块钱|块|¥)").find(text)
 val numToken=withUnit?.groupValues?.get(1)
  ?:Regex("[0-9]+(?:\\.[0-9]{1,2})?").find(text)?.value
 val amount=numToken?.let{tokenToDouble(it)}
 val category=guessCategory(text)
 var note=text
 if(withUnit!=null)note=note.replace(withUnit.value,"")
 else if(numToken!=null)note=note.replaceFirst(numToken,"")
 note=note.replace(Regex("\\s*(元|块钱|块|¥)\\s*"),"").trim().take(40)
 if(note.isBlank())note=category
 return ParsedExpense(amount,category,note)
}

fun fmtAmount(a:Double):String=if(a==a.toLong().toDouble())a.toLong().toString() else "%.2f".format(a)

/** 发给 Hermes 的记账消息：Hermes 负责落到 NAS 账本 */
fun expenseMessage(e:ParsedExpense):String="记一笔：${e.note} ${fmtAmount(e.amount?:0.0)}元"
