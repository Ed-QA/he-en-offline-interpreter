# Plays the real-voice Hebrew test audio through the PC speakers.
# Use: run this, put the iPhone (app running, mic listening) in front of the speakers.
param(
    [string]$File = "C:\Users\SHEdw\Desktop\music\txts\Hebrew Journaling From Simple Words to Real Fluency.mp3",
    [int]$Seconds = 0,      # 0 = play whole file
    [int]$StartAt = 0,      # start offset in seconds
    [int]$PauseEvery = 0    # if >0: pause 1.5s after every N seconds (tests the sense-gate on real pauses)
)

Add-Type -AssemblyName PresentationCore
$player = New-Object System.Windows.Media.MediaPlayer
$player.Open([Uri]$File)
$player.Volume = 1.0
Start-Sleep -Milliseconds 800
$total = $player.NaturalDuration.TimeSpan.TotalSeconds
Write-Output ("file duration: " + [math]::Round($total,1) + "s")

$player.Position = [TimeSpan]::FromSeconds($StartAt)
$player.Play()
$elapsed = 0.0
$limit = if ($Seconds -gt 0) { $Seconds } else { $total - $StartAt }

while ($elapsed -lt $limit) {
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
    if ($PauseEvery -gt 0 -and ([int]($elapsed / $PauseEvery) -gt [int](($elapsed - 0.5) / $PauseEvery))) {
        $player.Pause()
        Start-Sleep -Milliseconds 1500
        $player.Play()
    }
}
$player.Stop()
$player.Close()
Write-Output "playback done"
