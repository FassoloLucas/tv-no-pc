# Liga o LDPlayer ja abrindo um app, em tela cheia.
#   .\iniciar.ps1                        -> abre o YouCine
#   .\iniciar.ps1 -App com.exemplo.app   -> abre outro app
#   .\iniciar.ps1 -Janela                -> nao entra em tela cheia
param([string]$App, [switch]$Janela)

. "$PSScriptRoot\comum.ps1"
if (-not $App) { $App = $AppPadrao }

$inicio = Get-Date
if (-not (Test-LdLigado)) {
    # Se acabou de ser desligado, a maquina virtual leva ~8 s para fechar de vez;
    # ligar antes disso atrasa o boot e pega a janela antiga
    Wait-Process -Name 'Ld9BoxHeadless' -Timeout 60 -ErrorAction SilentlyContinue
    Write-Passo 'Ligando o LDPlayer'
    Invoke-Ld launch --index $Indice | Out-Null
    if (-not $Janela) { Wait-JanelaLd; Enter-TelaCheia }   # ja fica em tela cheia durante o boot
}
# Nao usamos o "ldconsole launchex": ele espera ~15 s a mais depois do boot para abrir o app
Wait-LdPronto
# Se o app ja esta na tela, nao abre de novo (o YouCine voltaria para a abertura e cortaria o filme)
if (-not (Test-AppNaFrente $App)) {
    Write-Passo "Abrindo $App"
    Start-App $App
    Wait-App $App
}
if (-not $Janela) { Enter-TelaCheia }
Write-Host ('Pronto em {0:N0} s.' -f ((Get-Date) - $inicio).TotalSeconds) -ForegroundColor Green
