# Instala um APK no TV, mostra se ele e compativel e abre o app.
#   .\instalar-apk.ps1 C:\Users\voce\Downloads\app.apk
param([Parameter(Mandatory)][string]$Apk)

. "$PSScriptRoot\comum.ps1"

$Apk = (Resolve-Path $Apk).Path
$pacote = $null

# O aapt (vem no build-tools do SDK) le o pacote e as arquiteturas do APK
$aapt = Get-ChildItem (Join-Path $SdkRoot 'build-tools') -Filter 'aapt.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($aapt) {
    Write-Passo 'Lendo o APK'
    $info = Invoke-Nativo $aapt.FullName dump badging $Apk 2>$null
    if ("$info" -match "package: name='([^']+)'") { $pacote = $Matches[1] }
    $nativo = $info | Where-Object { $_ -like 'native-code:*' }
    $tv     = $info | Where-Object { $_ -like 'leanback-launchable-activity:*' }
    Write-Host "Pacote:       $pacote"
    Write-Host "Codigo nativo: $(if ($nativo) { $nativo -replace '^native-code:\s*', '' } else { 'nenhum (roda em qualquer arquitetura)' })"
    Write-Host "Versao de TV:  $(if ($tv) { 'sim' } else { 'nao (versao de celular)' })"
}

if (-not (Test-EmuladorLigado)) { & "$PSScriptRoot\iniciar.ps1" }

Write-Passo "Instalando $(Split-Path $Apk -Leaf)"
Invoke-Adb install -r -g $Apk   # -g: ja concede as permissoes
if ($LASTEXITCODE -ne 0) { throw 'A instalacao falhou (veja a mensagem acima).' }

if ($pacote) {
    Write-Passo "Abrindo $pacote"
    Start-App $pacote
    Write-Host "`nPara abrir de novo depois:  .\emulador\iniciar.ps1 -App $pacote" -ForegroundColor Green
}
