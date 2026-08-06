<#
  Live S25-Ultra usage GUI: CPU / GPU / NPU + per-process backend + raw log.

  Run in its own window:
    powershell -Sta -NoProfile -ExecutionPolicy Bypass -File usage_gui.ps1

  Data source: one persistent `adb shell usage_stats.sh stream` process
  (1 line/sec). What the columns mean:
    CPU %  real  (/proc/stat delta)
    GPU %  real  (Adreno kgsl gpu_busy_percentage)
    NPU    NO true % exists non-root on this build (sysMonApp getstate/getinfo
           -> rc 44). Shown instead: live-session state from /proc/<pid>/fd on
           /dev/fastrpc-cdsp (kernel truth) + ipcc IRQ rate as an activity
           proxy, bar normalized to the peak rate seen this session.
#>
param(
    [string]$Serial = "192.168.137.2:5555"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$adb = "$env:LOCALAPPDATA\platform-tools\adb.exe"
if (-not (Test-Path $adb)) { [System.Windows.Forms.MessageBox]::Show("adb not found at $adb") | Out-Null; exit 1 }

# ---------- persistent stream ----------
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $adb
$psi.Arguments = "-s $Serial shell sh /data/local/tmp/usage_stats.sh stream"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$proc = [System.Diagnostics.Process]::Start($psi)

# NOTE: no Register-ObjectEvent here. PowerShell -Action event handlers never
# fire while the runspace is blocked inside ShowDialog, so a queue fed that way
# stays empty forever (the original bug: GUI showed no values). Instead the UI
# timer polls a ReadLineAsync task -- completed tasks are drained non-blocking.
$script:readTask = $proc.StandardOutput.ReadLineAsync()
$script:lastDataAt = Get-Date

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = "S25 Ultra live usage  ($Serial)"
$form.Size = New-Object System.Drawing.Size(760, 640)
$form.StartPosition = "CenterScreen"

function New-Row([string]$name, [int]$y, [System.Drawing.Color]$color) {
    $lab = New-Object System.Windows.Forms.Label
    $lab.Text = $name; $lab.Location = New-Object System.Drawing.Point(15, $y)
    $lab.Size = New-Object System.Drawing.Size(50, 22)
    $lab.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(70, $y)
    $bar.Size = New-Object System.Drawing.Size(480, 22)
    $bar.Style = "Continuous"; $bar.ForeColor = $color
    $val = New-Object System.Windows.Forms.Label
    $val.Location = New-Object System.Drawing.Point(560, $y)
    $val.Size = New-Object System.Drawing.Size(180, 22)
    $val.Font = New-Object System.Drawing.Font("Consolas", 9)
    $form.Controls.AddRange(@($lab, $bar, $val))
    @{ bar = $bar; val = $val }
}

$rowCpu = New-Row "CPU" 15 ([System.Drawing.Color]::DarkOrange)
$rowGpu = New-Row "GPU" 45 ([System.Drawing.Color]::DodgerBlue)
$rowNpu = New-Row "NPU" 75 ([System.Drawing.Color]::ForestGreen)

$npuNote = New-Object System.Windows.Forms.Label
$npuNote.Text = "NPU bar = IRQ-rate activity proxy (no root => no true %); session state is kernel-verified via /dev/fastrpc-cdsp fd"
$npuNote.Location = New-Object System.Drawing.Point(70, 100)
$npuNote.Size = New-Object System.Drawing.Size(660, 16)
$npuNote.ForeColor = [System.Drawing.Color]::Gray
$npuNote.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
$form.Controls.Add($npuNote)

$lv = New-Object System.Windows.Forms.ListView
$lv.View = "Details"; $lv.FullRowSelect = $true
$lv.Location = New-Object System.Drawing.Point(15, 125)
$lv.Size = New-Object System.Drawing.Size(715, 130)
[void]$lv.Columns.Add("PID", 70); [void]$lv.Columns.Add("Process", 190)
[void]$lv.Columns.Add("Backend (actual)", 120); [void]$lv.Columns.Add("RSS MB", 90)
$form.Controls.Add($lv)

$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ScrollBars = "Vertical"; $log.ReadOnly = $true
$log.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$log.Location = New-Object System.Drawing.Point(15, 265)
$log.Size = New-Object System.Drawing.Size(715, 300)
$log.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($log)

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(15, 572)
$status.Size = New-Object System.Drawing.Size(715, 20)
$status.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($status)

# ---------- timer ----------
$script:npuPeak = 100   # floor so an idle phone doesn't show a full bar on 1 irq
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $last = $null
    while ($script:readTask.IsCompleted) {
        $line = $script:readTask.Result
        $script:readTask = $proc.StandardOutput.ReadLineAsync()
        if ($null -eq $line) { break }   # EOF -- stream died
        $script:lastDataAt = Get-Date
        if ($line -like 'STAT *') { $last = $line }
        if ($log.Lines.Count -gt 400) { $log.Clear() }
        $log.AppendText("$line`r`n")
    }
    if (-not $last) {
        $age = ((Get-Date) - $script:lastDataAt).TotalSeconds
        if ($age -gt 5) {
            $status.Text = "no data for $([int]$age)s -- stream alive: $(-not $proc.HasExited). If dead: adb connect $Serial, then relaunch."
            $status.ForeColor = [System.Drawing.Color]::Red
        }
        return
    }
    $status.ForeColor = [System.Drawing.Color]::Black

    if ($last -match 'cpu=(\d+) gpu=(\d+) npu_irqps=(\d+) npu_pids=(\S+) cpuss=(\d+) procs=(\S*)') {
        $cpu = [Math]::Min(100, [int]$Matches[1])
        $gpu = [Math]::Min(100, [int]$Matches[2])
        $irq = [int]$Matches[3]
        $pids = $Matches[4]
        $temp = [int]$Matches[5] / 1000
        $procsRaw = $Matches[6]

        $rowCpu.bar.Value = $cpu; $rowCpu.val.Text = "$cpu %"
        $rowGpu.bar.Value = $gpu; $rowGpu.val.Text = "$gpu %"

        if ($irq -gt $script:npuPeak) { $script:npuPeak = $irq }
        $npuPct = [Math]::Min(100, [int](100 * $irq / $script:npuPeak))
        $active = ($pids -ne 'none')
        if ($active) { $rowNpu.bar.Value = $npuPct } else { $rowNpu.bar.Value = 0 }
        $state = "idle"; if ($active) { $state = "SESSION OPEN (pid $($pids.TrimEnd(',')))" }
        $rowNpu.val.Text = "$irq irq/s  $state"

        $lv.BeginUpdate(); $lv.Items.Clear()
        foreach ($p in ($procsRaw -split ';')) {
            if (-not $p) { continue }
            $f = $p -split ':'
            if ($f.Count -lt 4) { continue }
            $item = New-Object System.Windows.Forms.ListViewItem($f[0])
            [void]$item.SubItems.Add($f[1]); [void]$item.SubItems.Add($f[2]); [void]$item.SubItems.Add($f[3])
            switch ($f[2]) {
                "NPU" { $item.ForeColor = [System.Drawing.Color]::ForestGreen }
                "GPU" { $item.ForeColor = [System.Drawing.Color]::DodgerBlue }
                default { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
            }
            [void]$lv.Items.Add($item)
        }
        $lv.EndUpdate()

        $status.Text = "cpuss $($temp.ToString('N1')) C    stream alive: $(-not $proc.HasExited)    $(Get-Date -Format HH:mm:ss)"
    }
})
$timer.Start()

$form.Add_FormClosing({
    $timer.Stop()
    if (-not $proc.HasExited) { $proc.Kill() }
})

[void]$form.ShowDialog()
