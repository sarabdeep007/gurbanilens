package com.taajsingh.gurbanilens.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.taajsingh.gurbanilens.domain.SearchResult
import com.taajsingh.gurbanilens.domain.VoiceSearchSession
import com.taajsingh.gurbanilens.ui.home.HomeScreen
import com.taajsingh.gurbanilens.ui.recording.RecordingScreen
import com.taajsingh.gurbanilens.ui.results.ResultsScreen
import com.taajsingh.gurbanilens.ui.settings.SettingsScreen
import com.taajsingh.gurbanilens.ui.shabad.ShabadScreen
import com.taajsingh.gurbanilens.ui.theme.GurbaniLensTheme

/**
 * v1 nav graph. Pure-Compose wiring — Activity injects the session +
 * record/transcribe callbacks. Keeping nav declarative + dependencies
 * explicit so screens stay easy to preview / test in isolation.
 */
@Composable
fun AppNavGraph(
    session: VoiceSearchSession,
    onStartRecording: () -> Unit,
    onStopRecording: () -> Unit,
    onCancelRecording: () -> Unit,
    fetchShabadLines: suspend (shabadId: String) -> List<com.taajsingh.gurbanilens.core.Line>,
) {
    val navController = rememberNavController()
    val sessionState by session.state.collectAsState()
    val coroutineScope = rememberCoroutineScope()

    GurbaniLensTheme {
        NavHost(navController = navController, startDestination = Routes.HOME) {

            composable(Routes.HOME) {
                HomeScreen(
                    onSearchTap = {
                        onStartRecording()
                        navController.navigate(Routes.RECORDING)
                    },
                    onSettingsTap = { navController.navigate(Routes.SETTINGS) },
                )
            }

            composable(Routes.RECORDING) {
                val livePreview = (sessionState as? VoiceSearchSession.State.Done)
                    ?.result?.transcript.orEmpty()
                RecordingScreen(
                    session = session,
                    livePreview = livePreview,
                    onStop = {
                        onStopRecording()
                        // After stop, we wait for Done state then navigate.
                    },
                    onCancel = {
                        onCancelRecording()
                        session.reset()
                        navController.popBackStack(Routes.HOME, inclusive = false)
                    },
                )
                LaunchedAutoAdvance(navController, sessionState)
            }

            composable(Routes.RESULTS) {
                val result = (sessionState as? VoiceSearchSession.State.Done)?.result
                    ?: SearchResult.from("", emptyList())
                ResultsScreen(
                    result = result,
                    onBack = {
                        session.reset()
                        navController.popBackStack(Routes.HOME, inclusive = false)
                    },
                    onTryAgain = {
                        session.reset()
                        navController.popBackStack(Routes.HOME, inclusive = false)
                    },
                    onOpenShabad = { match ->
                        navController.navigate(Routes.shabad(match.line.shabadId, match.line.id))
                    },
                )
            }

            composable(
                route = Routes.SHABAD,
                arguments = listOf(
                    navArgument("shabadId") { type = NavType.StringType },
                    navArgument("focusLineId") { type = NavType.StringType },
                ),
            ) { entry ->
                val shabadId = entry.arguments?.getString("shabadId").orEmpty()
                val focusLineId = entry.arguments?.getString("focusLineId").orEmpty()
                val lines = remember(shabadId) {
                    androidx.compose.runtime.mutableStateOf<List<com.taajsingh.gurbanilens.core.Line>>(emptyList())
                }
                androidx.compose.runtime.LaunchedEffect(shabadId) {
                    lines.value = fetchShabadLines(shabadId)
                }
                ShabadScreen(
                    title = "Ang ${lines.value.firstOrNull()?.ang ?: ""}",
                    lines = lines.value,
                    focusLineId = focusLineId,
                    onBack = { navController.popBackStack() },
                    onShare = { /* TODO v1.1 — Android share sheet */ },
                )
            }

            composable(Routes.SETTINGS) {
                SettingsScreen(onBack = { navController.popBackStack() })
            }
        }
    }
}

@Composable
private fun LaunchedAutoAdvance(
    navController: androidx.navigation.NavController,
    state: VoiceSearchSession.State,
) {
    androidx.compose.runtime.LaunchedEffect(state) {
        if (state is VoiceSearchSession.State.Done) {
            navController.navigate(Routes.RESULTS) {
                popUpTo(Routes.HOME)
            }
        }
    }
}
