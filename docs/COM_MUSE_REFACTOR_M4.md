# M4 路由与补充去向

- Pi 主线提示词和 task_submit 策略加入最短路径规则、30秒/项目修改/显式委派条件、12字短标题与完整说明分离。无额外分类器回合。
- 补充的 request_id 与真实来源 message_id 存在 task JSON 的 input_sources；客户端不按文本/标题猜关联。
- 同一消息下显示补充到哪个任务及真实送达状态。
- POST /personal/tasks/{task_id}/inputs/{input_id}/new-item：未投递 accepted/pending_start/queued 可撤销，并从有效约束去除；sending/delivered/unknown 保持原状态，只另开事项并说明不能撤回。
- input_moves 保存新事项 identity，重试同号只产生一条新消息；不同新号拒绝。客户端提交前加密保存请求号。原 outbox/来源/未知不重放保持不变。
- 自然工作聊天在调用 Judge 前拒绝验收（补足 M3 的 guard）。

验证：本地相关34项通过；mini M3/M4与工作聊天相关58项通过；debug单测与构建成功；模拟器补充未送达/已送达/未知三个界面用例通过。
部署：Syncthing 对端六个后端文件 SHA256 一致。确认17条历史任务无在途任务、主对话无 queued/sending/running；SQLite在线备份到mini ~/.session-workbench/backups/com-m4-20261003-203556；随后加载 work.eddie.sessions。健康接口验证见执行记录。没有插入生产对话探针。
