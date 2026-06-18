package com.taajsingh.gurbanilens.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.taajsingh.gurbanilens.ui.theme.GurbaniLensTheme

enum class WhisperModelChoice(val display: String, val sizeMb: Int) {
    Tiny("tiny (40 MB)", 40),
    Base("base (150 MB)", 150),
    Small("small (250 MB)", 250),
    Medium("medium (500 MB) — download", 500),
}

enum class ScriptChoice(val display: String) {
    Gurmukhi("Unicode Gurmukhi"),
    Transliteration("Latin transliteration"),
    Both("Show both"),
}

enum class TranslationChoice(val display: String) {
    None("None"),
    BhaiManmohanSingh("Bhai Manmohan Singh"),
    SantSinghKhalsa("Sant Singh Khalsa"),
    PunjabiTeeka("Punjabi Teeka (Prof. Sahib Singh)"),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onBack: () -> Unit,
    initialModel: WhisperModelChoice = WhisperModelChoice.Tiny,
    initialScript: ScriptChoice = ScriptChoice.Both,
    initialTranslation: TranslationChoice = TranslationChoice.BhaiManmohanSingh,
    onSave: (WhisperModelChoice, ScriptChoice, TranslationChoice) -> Unit = { _, _, _ -> },
) {
    var model by remember { mutableStateOf(initialModel) }
    var script by remember { mutableStateOf(initialScript) }
    var translation by remember { mutableStateOf(initialTranslation) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = {
                        onSave(model, script, translation)
                        onBack()
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
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
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            SectionHeader("Whisper model")
            Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                WhisperModelChoice.entries.forEach { opt ->
                    RadioRow(
                        selected = model == opt,
                        label = opt.display,
                        onClick = { model = opt },
                    )
                }
            }

            SectionHeader("Default display script")
            Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                ScriptChoice.entries.forEach { opt ->
                    RadioRow(
                        selected = script == opt,
                        label = opt.display,
                        onClick = { script = opt },
                    )
                }
            }

            SectionHeader("Default translation")
            Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TranslationChoice.entries.forEach { opt ->
                    RadioRow(
                        selected = translation == opt,
                        label = opt.display,
                        onClick = { translation = opt },
                    )
                }
            }

            Spacer(Modifier.height(12.dp))
            AboutBlock()
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.primary,
        fontWeight = FontWeight.SemiBold,
    )
}

@Composable
private fun RadioRow(
    selected: Boolean,
    label: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Spacer(Modifier.padding(4.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun AboutBlock() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(8.dp))
            .padding(12.dp),
    ) {
        Text(
            text = "GurbaniLens — v1 voice-search",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Built as Seva by Taaj Studios. " +
                "Free for individuals and Gurdwaras forever. No ads, no tracking.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "ASR: whisper.cpp on-device · Matcher: rapidfuzz-equivalent " +
                "Indel-LCS · SGGS data: shabados/database v4.8.7.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun SettingsPreview() {
    GurbaniLensTheme(darkTheme = true) {
        SettingsScreen(onBack = {})
    }
}
