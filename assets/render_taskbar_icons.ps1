# Renders the PerplexForge icon set from PerplexForge_icon.svg's geometry, sized for the
# Windows taskbar / KiCad toolbar: transparent background (no dark square), artwork scaled
# to fill the canvas, and the trace moved 1 unit closer to the knot.
#
# The over/under weave is drawn by clipping the "under" strand at each crossing (instead of
# painting background-coloured strokes), so it looks right on any background.
#
#   powershell -STA -File render_taskbar_icons.ps1 -OutDir <folder>
param([string]$OutDir)
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$TraceShift = -1.0                                 # move the trace up (SVG units)
# artwork bounds incl. stroke widths, after the shift: x 3.75..21.25, y 2.0..21.25
$cx = 12.5; $cy = 11.625; $Scale = 23.2 / 19.25    # fill 23.2 of the 24-unit canvas

function Brush($hex) { $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)); $b.Freeze(); $b }
function MakePen($hex, $w, $round) {
    $p = New-Object System.Windows.Media.Pen (Brush $hex), $w
    if ($round) { $p.StartLineCap = "Round"; $p.EndLineCap = "Round"; $p.LineJoin = "Round" }
    else { $p.StartLineCap = "Flat"; $p.EndLineCap = "Flat"; $p.LineJoin = "Miter" }
    $p
}
function Rect($x0, $y0, $x1, $y1) { New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect $x0, $y0, ($x1 - $x0), ($y1 - $y0)) }
function Without($bands) {
    $grp = New-Object System.Windows.Media.GeometryGroup
    foreach ($b in $bands) { $grp.Children.Add($b) }
    New-Object System.Windows.Media.CombinedGeometry ([System.Windows.Media.GeometryCombineMode]::Exclude), (Rect -10 -10 40 40), $grp
}

$red  = "M10.1 2.95H13.9L15.2 4.25V14.65L13.9 15.95H10.1L8.8 14.65V4.25Z"
$blue = "M6.8 6.25H17.2L18.5 7.55V11.35L17.2 12.65H6.8L5.5 11.35V7.55Z"
# gap bands (the 3.1-wide strokes of the original) around each over-crossing
$redUnder  = @((Rect 7.2 4.7 10.4 7.8), (Rect 13.6 11.1 16.8 14.2))        # blue passes over red here
$blueUnder = @((Rect 13.65 4.65 16.75 7.85), (Rect 7.25 11.05 10.35 14.25)) # red passes over blue here
$overs = @(@("M6.9 6.25L10.7 6.25", "#5b8cff"), @("M15.2 4.35L15.2 8.15", "#ff5a5f"),
           @("M13.3 12.65L17.1 12.65", "#5b8cff"), @("M8.8 10.75L8.8 14.55", "#ff5a5f"))
$trace = "M4.4 21.6H6.2L7.2 18.5 8.8 21 10.2 19.3 11.6 20.8 12.9 19.9 14.2 20.4 15.5 20.1H20.6"

foreach ($size in 16, 24, 32, 48, 64, 128, 256) {
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $k = $size / 24.0
    $tg = New-Object System.Windows.Media.TransformGroup
    $tg.Children.Add((New-Object System.Windows.Media.TranslateTransform (-$cx), (-$cy)))
    $tg.Children.Add((New-Object System.Windows.Media.ScaleTransform $Scale, $Scale))
    $tg.Children.Add((New-Object System.Windows.Media.TranslateTransform 12, 12))
    $tg.Children.Add((New-Object System.Windows.Media.ScaleTransform $k, $k))
    $dc.PushTransform($tg)

    $dc.PushClip((Without $redUnder));  $dc.DrawGeometry($null, (MakePen "#ff5a5f" 1.9 $false), [System.Windows.Media.Geometry]::Parse($red));  $dc.Pop()
    $dc.PushClip((Without $blueUnder)); $dc.DrawGeometry($null, (MakePen "#5b8cff" 1.9 $false), [System.Windows.Media.Geometry]::Parse($blue)); $dc.Pop()
    foreach ($o in $overs) { $dc.DrawGeometry($null, (MakePen $o[1] 1.9 $false), [System.Windows.Media.Geometry]::Parse($o[0])) }

    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform 0, $TraceShift))
    $dc.DrawGeometry($null, (MakePen "#ff8a3d" 1.3 $true), [System.Windows.Media.Geometry]::Parse($trace))
    $dc.Pop()

    $dc.Pop(); $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $size, $size, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create((Join-Path $OutDir "icon_$size.png"))
    $enc.Save($fs); $fs.Close()
    "icon_$size.png"
}
