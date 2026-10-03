# M6 能力目录

基线已有 capability_search（com-pi.ts、agent_tools.py、CapabilityRegistry），没有新增第二个注册表。补足：

- 搜索只读取已有观察与当前配置文件，缺少观察时返回 discovered 的临时投影；不再通过查询偷偷写入 observe。
- 返回 name、description、provider、state、last_verified_at。描述与真实验证时间缺失返回 null。
- 保留配置改变使证据失效、24小时验证期限、跨主机隔离、fixture不能宣称verified。

验证：本地与 mini 各24项能力/主线契约测试通过；对端 capabilities.py 哈希核对。无在途任务与主对话，沿 M4 的可回滚部署流程加载。无需新UI；Pi已在M4提示词中知晓该工具。
