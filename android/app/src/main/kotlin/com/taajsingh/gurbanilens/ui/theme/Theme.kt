package com.taajsingh.gurbanilens.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val DarkColors = darkColorScheme(
    primary = Saffron,
    onPrimary = Indigo,
    secondary = SaffronDark,
    background = Indigo,
    onBackground = Cream,
    surface = IndigoLight,
    onSurface = Cream,
    surfaceVariant = IndigoMid,
    onSurfaceVariant = Ash,
    error = ErrorRose,
)

private val LightColors = lightColorScheme(
    primary = SaffronDark,
    onPrimary = Cream,
    secondary = Saffron,
    background = Cream,
    onBackground = Indigo,
    surface = Cream,
    onSurface = Indigo,
    surfaceVariant = Ash,
    onSurfaceVariant = DimAsh,
    error = ErrorRose,
)

@Composable
fun GurbaniLensTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = GurbaniLensTypography,
        content = content,
    )
}
