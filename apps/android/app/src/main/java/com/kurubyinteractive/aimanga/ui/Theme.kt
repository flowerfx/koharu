package com.kurubyinteractive.aimanga.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.MotionScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.kurubyinteractive.aimanga.data.ThemeMode

/** Pink of the app icon artwork (also `@color/brand_pink`). */
val BrandPink = Color(0xFFFF47B4)

// Material 3 tonal palettes generated around the icon's pink.
private val PinkLight = lightColorScheme(
    primary = Color(0xFFB0006E),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFFFD8E8),
    onPrimaryContainer = Color(0xFF3D0024),
    secondary = Color(0xFF735763),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFFFD8E6),
    onSecondaryContainer = Color(0xFF2A151F),
    tertiary = Color(0xFF006590),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFC8E6FF),
    onTertiaryContainer = Color(0xFF001E2F),
    background = Color(0xFFFFF8F9),
    onBackground = Color(0xFF22191C),
    surface = Color(0xFFFFF8F9),
    onSurface = Color(0xFF22191C),
    surfaceVariant = Color(0xFFF2DDE3),
    onSurfaceVariant = Color(0xFF514349),
    surfaceContainerLowest = Color(0xFFFFFFFF),
    surfaceContainerLow = Color(0xFFFFF0F4),
    surfaceContainer = Color(0xFFFBEAEF),
    surfaceContainerHigh = Color(0xFFF5E4E9),
    surfaceContainerHighest = Color(0xFFEFDFE3),
    outline = Color(0xFF837379),
    outlineVariant = Color(0xFFD5C2C8),
    error = Color(0xFFBA1A1A),
)

private val PinkDark = darkColorScheme(
    primary = Color(0xFFFFAFD3),
    onPrimary = Color(0xFF620040),
    primaryContainer = Color(0xFF8A0055),
    onPrimaryContainer = Color(0xFFFFD8E8),
    secondary = Color(0xFFE1BDCB),
    onSecondary = Color(0xFF412A34),
    secondaryContainer = Color(0xFF5A3F4B),
    onSecondaryContainer = Color(0xFFFFD8E6),
    tertiary = Color(0xFF8BCEFF),
    onTertiary = Color(0xFF00344D),
    tertiaryContainer = Color(0xFF004C6E),
    onTertiaryContainer = Color(0xFFC8E6FF),
    background = Color(0xFF191113),
    onBackground = Color(0xFFEFDFE3),
    surface = Color(0xFF191113),
    onSurface = Color(0xFFEFDFE3),
    surfaceVariant = Color(0xFF514349),
    onSurfaceVariant = Color(0xFFD5C2C8),
    surfaceContainerLowest = Color(0xFF130C0E),
    surfaceContainerLow = Color(0xFF22191C),
    surfaceContainer = Color(0xFF261D20),
    surfaceContainerHigh = Color(0xFF31282A),
    surfaceContainerHighest = Color(0xFF3C3235),
    outline = Color(0xFF9E8C92),
    outlineVariant = Color(0xFF514349),
    error = Color(0xFFFFB4AB),
)

private val RoundShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(20.dp),
    large = RoundedCornerShape(28.dp),
    extraLarge = RoundedCornerShape(32.dp),
)

@Composable
fun isDark(mode: ThemeMode): Boolean = when (mode) {
    ThemeMode.SYSTEM -> isSystemInDarkTheme()
    ThemeMode.LIGHT -> false
    ThemeMode.DARK -> true
}

/**
 * Material 3 Expressive theme in the icon's pink, light or dark. Material You
 * wallpaper colors replace the pink only when the user turns them on.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun KoharuTheme(mode: ThemeMode, dynamicColor: Boolean, content: @Composable () -> Unit) {
    val dark = isDark(mode)
    val context = LocalContext.current
    val colors = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        dark -> PinkDark
        else -> PinkLight
    }
    MaterialExpressiveTheme(
        colorScheme = colors,
        motionScheme = MotionScheme.expressive(),
        shapes = RoundShapes,
        content = content,
    )
}
