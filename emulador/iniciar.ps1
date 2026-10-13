# Liga o TV (se ainda nao estiver ligado) e, opcionalmente, abre um app.
#   .\iniciar.ps1                        -> so liga
#   .\iniciar.ps1 -App com.exemplo.app   -> liga e abre o app
param([string]$App)

. "$PSScriptRoot\comum.ps1"

if (Test-EmuladorLigado) {
    Write-Host 'O TV ja esta ligado.'
} else {
    Write-Passo 'Ligando o TV'
    $inicio = Get-Date
    Start-Emulador
    Wait-AndroidPronto
    Write-Host ('Ligado em {0:N0} s.' -f ((Get-Date) - $inicio).TotalSeconds) -ForegroundColor Green
}

if ($App) {
    Write-Passo "Abrindo $App"
    Start-App $App
}
