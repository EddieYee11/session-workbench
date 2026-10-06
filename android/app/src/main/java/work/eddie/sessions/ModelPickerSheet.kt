package work.eddie.sessions

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The models and effort levels come from the connected agent, never a hard-coded catalog. */
data class ModelChoice(
    val id: String,
    val label: String,
    val provider: String,
    val efforts: List<String>,
    val defaultEffort: String = "",
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelPickerSheet(
    agent: String,
    models: List<ModelChoice>,
    selectedModel: String,
    selectedEffort: String,
    loading: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onApply: (String, String) -> Unit,
    onRetry: () -> Unit,
    existingSession: Boolean = false,
    allowDefaultModel: Boolean = true,
) {
    var draftModel by rememberSaveable(agent, selectedModel, selectedEffort) {
        mutableStateOf(selectedModel)
    }
    var draftEffort by rememberSaveable(agent, selectedModel, selectedEffort) {
        mutableStateOf(selectedEffort)
    }
    var query by rememberSaveable(agent) { mutableStateOf("") }
    val chosen = models.firstOrNull { draftModel.isNotBlank() && it.id == draftModel }
    val availableEfforts = chosen?.efforts.orEmpty().filter { it.isNotBlank() }.distinct()
    val filteredModels = models.filter { it.id.isNotBlank() }.distinctBy { it.id }.filter { model ->
        query.isBlank() || listOf(model.label, model.provider, model.id).any {
            it.contains(query.trim(), ignoreCase = true)
        }
    }
    val haptics = rememberComHaptics()
    val agentName = agentDisplayName(agent)
    val listState = remember(agent) { LazyListState() }
    LaunchedEffect(agent, models.size, query) {
        if (models.isNotEmpty()) listState.scrollToItem(0)
    }
    LaunchedEffect(chosen?.id, availableEfforts) {
        if (chosen != null && draftEffort.isNotBlank() && draftEffort !in availableEfforts) {
            draftEffort = chosen.defaultEffort.takeIf { it in availableEfforts }.orEmpty()
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
        sheetMaxWidth = 520.dp,
        shape = RoundedCornerShape(topStart = Radii.Sheet, topEnd = Radii.Sheet),
        containerColor = Paper,
        tonalElevation = 0.dp,
        dragHandle = {
            Box(
                Modifier.padding(top = 12.dp, bottom = 6.dp)
                    .size(width = 32.dp, height = 4.dp)
                    .background(Line, CircleShape)
            )
        },
    ) {
        Column(
            Modifier.fillMaxWidth().heightIn(max = 560.dp).navigationBarsPadding()
        ) {
            Row(
                Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 8.dp, bottom = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("模型与推理", color = Ink, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
                    Text(agentName, color = Muted, fontSize = 13.sp)
                }
                IconButton(onClick = onDismiss, modifier = Modifier.size(48.dp)) {
                    Icon(Icons.Outlined.Close, contentDescription = "关闭模型选择", tint = Muted)
                }
            }

            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                PickerSectionLabel("模型")
                if (allowDefaultModel) PickerOption(
                    title = "跟随 Mac 默认",
                    subtitle = "使用当前 Agent 的默认模型",
                    selected = draftModel.isBlank(),
                    onClick = {
                        if (draftModel.isNotBlank()) haptics(HapticCue.Selection)
                        draftModel = ""
                        draftEffort = ""
                    },
                ) else Text(
                    "此会话已指定模型；恢复 Mac 默认请新建会话。",
                    Modifier.padding(horizontal = 12.dp, vertical = 12.dp),
                    color = Muted, fontSize = 12.sp,
                )
                if (selectedModel.isNotBlank() && models.none { it.id == selectedModel }) {
                    PickerOption(
                        title = selectedModel,
                        subtitle = if (loading) "当前设置 · 正在验证可用性" else "当前设置 · 尚未验证可用性",
                        selected = draftModel == selectedModel,
                        onClick = {
                            if (draftModel != selectedModel) haptics(HapticCue.Selection)
                            draftModel = selectedModel
                            draftEffort = selectedEffort
                        },
                    )
                }
                if (models.isNotEmpty()) {
                    PickerSearchField(query = query, onQueryChange = { query = it })
                }
            }

            val selectModel: (ModelChoice) -> Unit = { model ->
                if (draftModel != model.id) haptics(HapticCue.Selection)
                draftModel = model.id
                if (draftEffort.isNotBlank() && draftEffort !in model.efforts) {
                    draftEffort = model.defaultEffort.takeIf { it in model.efforts }.orEmpty()
                }
            }
            LazyColumn(
                Modifier.weight(1f, fill = false).padding(horizontal = 16.dp),
                state = listState,
                contentPadding = PaddingValues(bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (models.isNotEmpty() && filteredModels.isEmpty()) {
                    item(key = "no-model-match") {
                        Text(
                            "没有匹配的模型",
                            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 18.dp),
                            color = Muted,
                            fontSize = 13.sp,
                        )
                    }
                } else if (query.isBlank()) {
                    filteredModels.groupBy { it.provider.ifBlank { "其他" } }.forEach { (provider, group) ->
                        item(key = "provider:$provider") { PickerSectionLabel(provider) }
                        items(group, key = { "model:${it.id}" }) { model ->
                            PickerModelOption(model, draftModel == model.id) { selectModel(model) }
                        }
                    }
                } else {
                    items(filteredModels, key = { "model:${it.id}" }) { model ->
                        PickerModelOption(model, draftModel == model.id) { selectModel(model) }
                    }
                }

                if (models.isEmpty()) {
                    when {
                        loading -> item(key = "loading") {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Muted)
                                Text("正在读取可用模型…", Modifier.padding(start = 12.dp), color = Muted, fontSize = 13.sp)
                            }
                        }
                        else -> item(key = "load-error") {
                            Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp)) {
                                Text(error?.takeIf { it.isNotBlank() } ?: "暂时无法读取模型列表", color = Muted, fontSize = 13.sp)
                                TextButton(onClick = onRetry) { Text("重新加载", color = Ink) }
                            }
                        }
                    }
                }
                if (draftModel.isNotBlank() && chosen == null && !loading) {
                    item(key = "unavailable-selection") {
                        Text(
                            "可保留当前设置；它是否仍可用，要等 Mac 恢复连接后确认。",
                            Modifier.padding(start = 12.dp, top = 4.dp, bottom = 8.dp),
                            color = Muted,
                            fontSize = 12.sp,
                        )
                    }
                }

                item(key = "effort-heading") {
                    Column {
                        Spacer(Modifier.height(12.dp))
                        HorizontalDivider(color = Line)
                        Spacer(Modifier.height(12.dp))
                        PickerSectionLabel("推理水平")
                    }
                }
                item(key = "effort-default") {
                    PickerOption(
                        title = if (agent == "pi" && existingSession) "沿用当前推理强度" else "跟随默认",
                        subtitle = if (draftModel.isBlank()) "由 Mac 当前配置决定" else if (existingSession) "切换模型时保留 ${agentDisplayName(agent)} 当前强度" else "由所选模型决定",
                        selected = draftEffort.isBlank(),
                        onClick = {
                            if (draftEffort.isNotBlank()) haptics(HapticCue.Selection)
                            draftEffort = ""
                        },
                    )
                }
                items(availableEfforts, key = { "effort:$it" }) { effort ->
                    PickerOption(
                        title = effortLabel(effort),
                        subtitle = effort,
                        selected = draftEffort == effort,
                        onClick = {
                            if (draftEffort != effort) haptics(HapticCue.Selection)
                            draftEffort = effort
                        },
                    )
                }
                if (chosen == null && draftModel.isNotBlank() && draftEffort.isNotBlank()) {
                    item(key = "effort-unverified") {
                        PickerOption(
                            title = draftEffort,
                            subtitle = "当前推理设置 · 尚未验证可用性",
                            selected = true,
                            onClick = {},
                        )
                    }
                }
                if (chosen == null) {
                    item(key = "effort-hint") {
                        Text(
                            if (draftModel.isBlank()) "选择模型后，会显示它提供的推理水平。"
                            else "当前模型未提供可验证的推理选项，可继续保留原设置或跟随默认。",
                            Modifier.padding(start = 12.dp, top = 2.dp, bottom = 12.dp),
                            color = Muted,
                            fontSize = 12.sp,
                        )
                    }
                } else if (availableEfforts.isEmpty()) {
                    item(key = "effort-hint") {
                        Text(
                            "此模型未提供单独的推理水平设置。",
                            Modifier.padding(start = 12.dp, top = 2.dp, bottom = 12.dp),
                            color = Muted,
                            fontSize = 12.sp,
                        )
                    }
                }
            }

            HorizontalDivider(color = Line)
            Text(
                "从下一条消息生效",
                Modifier.fillMaxWidth().padding(top = 12.dp),
                color = Muted,
                fontSize = 12.sp,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            Button(
                onClick = {
                    haptics(HapticCue.Commit)
                    val effort = when {
                        draftModel.isBlank() -> ""
                        chosen == null && draftModel == selectedModel -> draftEffort
                        draftEffort in availableEfforts -> draftEffort
                        else -> chosen?.defaultEffort?.takeIf { it in availableEfforts }.orEmpty()
                    }
                    onApply(draftModel, effort)
                },
                enabled = (allowDefaultModel && draftModel.isBlank()) || chosen != null || (draftModel.isNotBlank() && draftModel == selectedModel),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp).height(52.dp),
                shape = RoundedCornerShape(16.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Ember, contentColor = Color.White),
            ) {
                Text("应用选择", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun PickerSectionLabel(title: String) {
    Text(
        title,
        Modifier.padding(start = 12.dp, top = 2.dp, bottom = 4.dp),
        color = Muted,
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
    )
}

@Composable
private fun PickerSearchField(query: String, onQueryChange: (String) -> Unit) {
    Surface(
        Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 8.dp),
        shape = RoundedCornerShape(Radii.M),
        color = Color.White,
        border = BorderStroke(1.dp, Line),
    ) {
        Row(
            Modifier.fillMaxWidth().height(46.dp).padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.Search, contentDescription = null, modifier = Modifier.size(19.dp), tint = Muted)
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                modifier = Modifier.weight(1f).padding(start = 10.dp),
                singleLine = true,
                textStyle = TextStyle(fontSize = 14.sp, color = Ink),
                cursorBrush = SolidColor(Ink),
                decorationBox = { inner ->
                    Box {
                        if (query.isBlank()) Text("搜索名称、提供方或 ID", color = Muted, fontSize = 14.sp)
                        inner()
                    }
                },
            )
            if (query.isNotBlank()) {
                IconButton(onClick = { onQueryChange("") }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Outlined.Close, contentDescription = "清除搜索", modifier = Modifier.size(17.dp), tint = Muted)
                }
            }
        }
    }
}

@Composable
private fun PickerModelOption(model: ModelChoice, selected: Boolean, onClick: () -> Unit) {
    PickerOption(
        title = model.label.ifBlank { model.id },
        subtitle = model.provider.ifBlank { model.id },
        selected = selected,
        onClick = onClick,
    )
}

@Composable
private fun PickerOption(title: String, subtitle: String, selected: Boolean, onClick: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth().selectable(
            selected = selected,
            role = Role.RadioButton,
            onClick = onClick,
        ),
        shape = RoundedCornerShape(14.dp),
        color = if (selected) EmberSoft else Color.Transparent,
        border = if (selected) BorderStroke(1.dp, Ember.copy(alpha = .5f)) else null,
    ) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 58.dp).padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, color = Ink, fontSize = 15.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (subtitle.isNotBlank()) {
                    Text(subtitle, color = Muted, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
            if (selected) {
                Spacer(Modifier.width(12.dp))
                Icon(Icons.Outlined.Check, contentDescription = null, modifier = Modifier.size(20.dp), tint = Ink)
            }
        }
    }
}

private fun effortLabel(effort: String): String = when (effort.lowercase()) {
    "off" -> "关闭推理"
    "minimal" -> "极简"
    "low" -> "低"
    "medium" -> "中"
    "high" -> "高"
    "xhigh" -> "极高"
    "max" -> "最高"
    else -> effort
}
