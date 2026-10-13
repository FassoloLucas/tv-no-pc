# Faz o servidor do controle ligar sozinho (escondido) quando voce entra no Windows.
#   .\iniciar-com-windows.ps1           -> coloca na inicializacao e ja liga o servidor
#   .\iniciar-com-windows.ps1 -Remover  -> tira da inicializacao e desliga o servidor
param([switch]$Remover)

$ErrorActionPreference = 'Stop'
$atalho   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Controle da TV.lnk'
$servidor = Join-Path $PSScriptRoot 'servidor.js'
$log      = Join-Path $PSScriptRoot 'servidor.log'

function Stop-Servidor {
    # O PowerShell escondido primeiro (senao ele religa o node), depois o node
    foreach ($nome in 'powershell.exe', 'node.exe') {
        Get-CimInstance Win32_Process -Filter "Name='$nome'" |
            Where-Object { $_.CommandLine -like "*$servidor*" -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    }
}

if ($Remover) {
    Remove-Item $atalho -ErrorAction SilentlyContinue
    Stop-Servidor
    Write-Host 'O controle nao liga mais com o Windows.'
    return
}

$node = (Get-Command node -ErrorAction Stop).Source
# Se o servidor cair, volta sozinho em 5 s. A saida dele fica em servidor.log.
$comando = "while (`$true) { & '$node' '$servidor' *> '$log'; Start-Sleep 5 }"

$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($atalho)
$lnk.TargetPath  = (Get-Command powershell.exe).Source
$lnk.Arguments   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$comando`""
$lnk.WindowStyle = 7   # minimizado: nao pisca janela antes do -WindowStyle Hidden
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Description = 'Servidor do controle remoto da TV'
$lnk.Save()

Stop-Servidor
# Abre pelo Explorer: assim o servidor nao fica preso a este terminal (fechar o terminal nao derruba)
Start-Process explorer.exe "`"$atalho`""
Start-Sleep 3
Write-Host "Pronto: o controle liga junto com o Windows."
Get-Content $log -ErrorAction SilentlyContinue
