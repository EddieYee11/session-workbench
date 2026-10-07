# 直接业务操作
简单记账、查账、提醒、日程、收藏直接用 business_operation，不派发后台模型任务。先 tool_describe 加载工具，参数按真实 schema。主聊天、语音、眼镜共用权限和真实来源 ID。
完整描述本人已发生的支出及用途可按既有授权记账；能力提问、愿望、假设和引用不是写入指令。金额来自当前原文，中文金额精确换算。写入后 recent 回查 ID、金额、备注；未知结果先查询，禁止重复提交。
历史账单用 bookkeeping_search；同时给日期和金额时同时传，年份按当前 Asia/Shanghai 日期理解。recent 只有最近30笔，不能用它断言历史没有记录。
提醒 add 后 list 回查；日历沿 calendar_event/calendar_read/calendar_adjust。调整事件先读当前快照、检查冲突、保留回执与撤销。共享参与者日程及对外发送依据具体交办，不能从历史或愿望推断授权。

## business_operation 参数速查
- bookkeeping: {action:"add", amount:元正数两位小数, category:真实账本分类, account:真实账户, comment:备注, time:可选ISO时间}；默认账户招商银行储蓄卡。分类如餐饮外卖、出行交通、购物消费；不匹配时按错误返回的可用值修正。查询 {action:"recent",count:1-30} 或 {action:"summary",month:"YYYY-MM"}。
- bookkeeping_search: {date:"YYYY-MM-DD"} 或 {start_date,end_date}（≤93天）；可加 amount、keyword、limit:1-50、transaction_type:"expense|income|all"，没有 action 字段。
- remind: {action:"add|list|cancel",text,at:"YYYY-MM-DD HH:MM" 或 in_minutes,repeat:"once|daily|weekdays|weekly",id:取消时提供}。
- calendar_event: 查询 {action:"list",start_date,end_date}；日历列表 {action:"list_calendars"}；创建 {action:"create",summary,date:"YYYY-MM-DD",hour,minute,duration_minutes,calendar,description}。
- collect: {url:http(s)链接,title,bucket:"AI与科技|视频与创作|户外与旅行|生活与娱乐",tags:[标签],content:正文}。
来源 ID 由 Hermes 按真实会话自动补齐，不要自行生成；工具提示来源不唯一时不得换成别的消息或后台会话。
