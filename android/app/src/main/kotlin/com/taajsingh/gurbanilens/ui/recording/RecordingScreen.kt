package com.taajsingh.gurbanilens.ui.recording

import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.taajsingh.gurbanilens.R
import com.taajsingh.gurbanilens.domain.VoiceSearchSession
import com.taajsingh.gurbanilens.ui.theme.GurbaniLensTheme
import kotlinx.coroutines.flow.MutableStateFlow

@Composable
fun RecordingScreen(
    session: VoiceSearchSession,
    livePreview: String,
    onStop: () -> Unit,
    onCancel: () -> Unit,
) {
    val state by session.state.collectAsState()
    val peak: Float = when (state) {
        is VoiceSearchSession.State.Recording -> (state as VoiceSearchSession.State.Recording).peak
        VoiceSearchSession.State.Transcribing -> 1f
        else -> 0f
    }
    val pulse by animateFloatAsState(
        targetValue = 1f + peak * 0.4f,
        label = "mic-pulse",
    )

    val statusLabel = when (state) {
        is VoiceSearchSession.State.Recording -> "Listening…"
        VoiceSearchSession.State.Transcribing -> "Transcribing…"
        is VoiceSearchSession.State.Error -> "Error"
        else -> ""
    }

    Scaffold { pad ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(pad)
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(top = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = statusLabel,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.height(48.dp))
                Box(
                    modifier = Modifier
                        .size(180.dp)
                        .scale(pulse)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.primary),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painter = painterResource(id = R.drawable.ic_mic),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(80.dp),
                    )
                }
                Spacer(Modifier.height(32.dp))
                if (livePreview.isNotEmpty()) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .background(MaterialTheme.colorScheme.surface)
                            .padding(16.dp),
                    ) {
                        Text(
                            text = livePreview,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                            fontFamily = FontFamily.Monospace,
                            textAlign = TextAlign.Start,
                        )
                    }
                } else {
                    Text(
                        text = "Recite a Pangti aloud.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 32.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                OutlinedButton(onClick = onCancel) {
                    Icon(Icons.Default.Close, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Cancel")
                }
                Button(
                    onClick = onStop,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary,
                    ),
                ) {
                    Icon(Icons.Default.Check, contentDescription = null)
                    Spacer(Modifier.size(8.dp))
                    Text("Done")
                }
            }
        }
    }
}

@Preview(showBackground = true, name = "Recording — listening")
@Composable
private fun RecordingScreenPreview() {
    GurbaniLensTheme(darkTheme = true) {
        val session = VoiceSearchSession().apply { setRecording(0.6f) }
        RecordingScreen(session = session, livePreview = "", onStop = {}, onCancel = {})
    }
}
