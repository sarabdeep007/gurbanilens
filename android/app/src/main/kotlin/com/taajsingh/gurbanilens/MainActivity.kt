package com.taajsingh.gurbanilens

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview

/**
 * v1 entry point — placeholder. Real screens (Home / Recording / Results /
 * Shabad / Settings) land in the next commit on this branch.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Placeholder()
                }
            }
        }
    }
}

@Composable
private fun Placeholder() {
    Text("GurbaniLens — v1 voice-search scaffold.")
}

@Preview(showBackground = true)
@Composable
private fun PlaceholderPreview() {
    MaterialTheme { Placeholder() }
}
