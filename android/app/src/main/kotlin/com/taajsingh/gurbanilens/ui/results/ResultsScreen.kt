package com.taajsingh.gurbanilens.ui.results

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.taajsingh.gurbanilens.core.Line
import com.taajsingh.gurbanilens.core.Match
import com.taajsingh.gurbanilens.domain.ConfidenceLabel
import com.taajsingh.gurbanilens.domain.SearchResult
import com.taajsingh.gurbanilens.ui.theme.ErrorRose
import com.taajsingh.gurbanilens.ui.theme.GurbaniLensTheme
import com.taajsingh.gurbanilens.ui.theme.SuccessGreen
import com.taajsingh.gurbanilens.ui.theme.WarningAmber

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ResultsScreen(
    result: SearchResult,
    onBack: () -> Unit,
    onTryAgain: () -> Unit,
    onOpenShabad: (Match) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Search results") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = onTryAgain) {
                        Icon(Icons.Default.Refresh, contentDescription = "Try again")
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
            TranscriptStrip(transcript = result.transcript)
            Spacer(Modifier.height(16.dp))
            ConfidencePill(label = result.topConfidence)
            Spacer(Modifier.height(16.dp))

            val top = result.top
            if (top == null) {
                EmptyState(onTryAgain)
            } else {
                MatchCard(
                    match = top,
                    isTopMatch = true,
                    onClick = { onOpenShabad(top) },
                )
                if (result.alternates.isNotEmpty()) {
                    Spacer(Modifier.height(24.dp))
                    Text(
                        text = "Did you mean…",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(8.dp))
                    LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        items(result.alternates) { alt ->
                            MatchCard(
                                match = alt,
                                isTopMatch = false,
                                onClick = { onOpenShabad(alt) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptStrip(transcript: String) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(12.dp),
    ) {
        Column {
            Text(
                text = "You said:",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = transcript.ifEmpty { "(no transcript)" },
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

@Composable
private fun ConfidencePill(label: ConfidenceLabel) {
    val color: Color = when (label) {
        ConfidenceLabel.Strong -> SuccessGreen
        ConfidenceLabel.Possible -> WarningAmber
        ConfidenceLabel.Low -> ErrorRose
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .background(color, RoundedCornerShape(5.dp)),
        )
        Spacer(Modifier.size(8.dp))
        Text(
            text = label.display,
            style = MaterialTheme.typography.bodyLarge,
            color = color,
            fontWeight = FontWeight.Medium,
        )
    }
}

@Composable
private fun MatchCard(
    match: Match,
    isTopMatch: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(
                if (isTopMatch) MaterialTheme.colorScheme.surfaceVariant
                else MaterialTheme.colorScheme.surface
            )
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Column {
            Row {
                Text(
                    text = "Ang ${match.line.ang}" +
                        (match.line.pangti?.let { " · Pangti $it" } ?: ""),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.weight(1f))
                match.line.lineType?.let {
                    AssistChip(
                        onClick = {},
                        label = { Text(it) },
                        colors = AssistChipDefaults.assistChipColors(
                            containerColor = MaterialTheme.colorScheme.background,
                        ),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = match.line.transliterationEn ?: match.line.gurmukhi,
                style = if (isTopMatch) MaterialTheme.typography.headlineMedium
                else MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface,
                fontWeight = if (isTopMatch) FontWeight.Medium else FontWeight.Normal,
            )
        }
    }
}

@Composable
private fun EmptyState(onTryAgain: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "No matches found.",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "Try reciting more of the Pangti, or speak more clearly.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Preview(showBackground = true, name = "Results — strong match")
@Composable
private fun ResultsPreview() {
    GurbaniLensTheme(darkTheme = true) {
        val fake = Line(
            id = "ABC", shabadId = "CWK", ang = 462, pangti = 3,
            lineType = "Pankti", gurmukhi = "mInw jlhIn",
            gurmukhiUnicode = null,
            transliterationEn = "meenaa jalaheen meenaa jalaheen he",
            firstLetters = "mjmjh", orderId = 10000,
        )
        val match = Match(fake, score = 95.0, partialRatio = 95.0, coverage = 1.0)
        val result = SearchResult.from("meena jalheen meena jalheen he", listOf(match))
        ResultsScreen(result = result, onBack = {}, onTryAgain = {}, onOpenShabad = {})
    }
}
