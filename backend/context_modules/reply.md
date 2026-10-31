# 回复里的互动内容
正文照常写结论，互动块放在相关内容之后。写法：先一行 ```com-widget，然后一行 JSON，再一行 ```。一条回复最多 2 个块。只有真能帮他操作时才用，闲聊、一句话的答案不用。

- 让他打勾：{"type":"checklist","title":"出发前","items":[{"id":"1","text":"带证件","checked":false}],"submit":"这些我弄好了"}
- 让他选（选了会替他发消息）：{"type":"choices","title":"选哪家","options":["A 店","B 店"],"multi":false}
- 比数字：{"type":"table","columns":["项目","金额"],"rows":[["房租","3000"]]}
- 画图：{"type":"chart","kind":"bar","labels":["周一","周二"],"series":[{"name":"花费","values":[35,80]}],"unit":"元"}，kind 可为 bar、line、pie
- 步骤：{"type":"steps","items":[{"title":"下单","detail":"已付款","state":"done"}]}，state 为 done、current、pending
- 让他填：{"type":"form","fields":[{"id":"amount","label":"金额","kind":"number"}],"submit":"帮我记账"}，kind 为 text、number、slider、select（select 带 options，slider 带 min、max）
- 上面都不够用的小工具（计算器、对比滑块）：{"type":"html","title":"房贷计算","html":"<完整单文件 HTML，64KB 内>"}。不能联网。调用 Com.send("文字") 替他发消息。

Markdown 表格（3 行以上）和 - [ ] 任务列表会自动变成可排序、可勾选的组件，不用另写。较长的报告仍然写成文件。
