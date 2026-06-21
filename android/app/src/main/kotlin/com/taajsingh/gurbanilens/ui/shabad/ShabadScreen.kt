package com.taajsingh.gurbanilens.ui.shabad

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.taajsingh.gurbanilens.core.Line
import com.taajsingh.gurbanilens.ui.theme.GurbaniLensTheme

enum class ScriptToggle { Gurmukhi, Transliteration, Both }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShabadScreen(
    title: String,
    lines: List<Line>,
    focusLineId: String?,
    onBack: () -> Unit,
    onShare: () -> Unit,
) {
    var script by remember { mutableStateOf(ScriptToggle.Both) }
    var showEnglish by remember { mutableStateOf(true) }

    val listState = rememberLazyListState()
    LaunchedEffect(focusLineId, lines) {
        val idx = lines.indexOfFirst { it.id == focusLineId }
        if (idx >= 0) listState.animateScrollToItem(idx)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onShare) {
                        Icon(Icons.Default.Share, contentDescription = "Share")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
    ) { pad ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(pad)
                .padding(horizontal = 16.dp),
        ) {
            // Script toggles
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ScriptToggle.entries.forEach { opt ->
                    FilterChip(
                        selected = script == opt,
                        onClick = { script = opt },
                        label = { Text(opt.name) },
                        colors = FilterChipDefaults.filterChipColors(),
                    )
                }
                Spacer(Modifier.weight(1f))
                FilterChip(
                    selected = showEnglish,
                    onClick = { showEnglish = !showEnglish },
                    label = { Text("English") },
                )
            }
            Spacer(Modifier.height(12.dp))

            LazyColumn(
                state = listState,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(lines, key = { it.id }) { line ->
                    LineRow(
                        line = line,
                        script = script,
                        showEnglish = showEnglish,
                        focused = line.id == focusLineId,
                    )
                }
            }
        }
    }
}

@Composable
private fun LineRow(
    line: Line,
    script: ScriptToggle,
    showEnglish: Boolean,
    focused: Boolean,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(
                if (focused) MaterialTheme.colorScheme.surfaceVariant
                else MaterialTheme.colorScheme.surface
            )
            .padding(12.dp),
    ) {
        Column {
            if (script != ScriptToggle.Transliteration) {
                Text(
                    text = line.gurmukhiUnicode ?: line.gurmukhi,
                    style = MaterialTheme.typography.headlineMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    fontWeight = FontWeight.Medium,
                )
            }
            val translit = line.transliterationEn
            if (script != ScriptToggle.Gurmukhi && translit != null) {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = translit,
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontFamily = FontFamily.Monospace,
                )
            }
            // English translation surface is bundled in the app DB as a
            // separate column we haven't wired yet (depends on the Anvaad-
            // augmented build). For v1 placeholder text.
            if (showEnglish) {
                Spacer(Modifier.height(6.dp))
                Text(
                    text = "(English translation will appear here in the next data-pipeline pass.)",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Preview(showBackground = true, name = "Shabad — focused")
@Composable
private fun ShabadPreview() {
    GurbaniLensTheme(darkTheme = true) {
        val lines = listOf(
            Line("a", "CWK", 462, 1, "Sirlekh", "Aasaa", null, "aasaa", null, 9998),
            Line("b", "CWK", 462, 2, "Pankti", "kbIr", null, "kabeer", null, 9999),
            Line("c", "CWK", 462, 3, "Pankti", "mInw", null, "meenaa jalaheen", null, 10000),
            Line("d", "CWK", 462, 4, "Pankti", "kwhy", null, "kahe naanak", null, 10001),
        )
        ShabadScreen("CWK", lines, focusLineId = "c", onBack = {}, onShare = {})
    }
}
