# Instala e prepara o LDPlayer 9 para funcionar como TV.
# Pode rodar de novo sem problema (so instala se ainda nao estiver instalado).
#   .\setup.ps1                     -> instala/configura
#   .\setup.ps1 -Apk C:\...\app.apk -> tambem instala um app
param([string]$Apk)

. "$PSScriptRoot\comum.ps1"

if (-not (Test-Path $LdConsole)) {
    Write-Passo 'Baixando o instalador oficial do LDPlayer 9'
    $pasta = Join-Path $env:TEMP "ldplayer-$(Get-Random)"
    New-Item -ItemType Directory $pasta | Out-Null
    $exe = Join-Path $pasta 'LDPlayer9.exe'
    $ProgressPreference = 'SilentlyContinue'   # a barra de progresso deixa o download muito lento no PowerShell 5.1
    Invoke-WebRequest $LdInstalador -OutFile $exe -UseBasicParsing
    $assinatura = Get-AuthenticodeSignature $exe
    if ($assinatura.Status -ne 'Valid' -or $assinatura.SignerCertificate.Subject -notmatch $LdAssinante) {
        throw "O instalador baixado nao tem a assinatura do LDPlayer ($($assinatura.Status))."
    }

    Write-Passo "Instalando em $LdDir (baixa ~800 MB, leva alguns minutos)"
    # -silence instala sem perguntar nada; o instalador liga o LDPlayer quando termina
    Start-Process $exe -ArgumentList '-silence', "-path=`"$LdDir`"" -Wait
    $limite = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $limite -and -not (Get-Process -Name 'dnplayer' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 5
    }
    if (-not (Test-Path $LdConsole)) { throw 'A instalacao do LDPlayer falhou.' }
} else {
    Write-Passo "LDPlayer ja instalado em $LdHome"
}

Write-Passo 'Aplicando as configuracoes de TV'
Stop-Ld
Invoke-Ld modify --index $Indice @LdHardware | Out-Null
# fastplay: modo rapido; cleanmode: sem anuncios na tela inicial
# (sem --audio: ele liga o "reduzir audio", que deixa o som baixo)
Invoke-Ld globalsetting --fps 60 --fastplay 1 --cleanmode 1 | Out-Null
Set-LdJson (Join-Path $LdConfig "leidian$Indice.config") @{ 'basicSettings.adbDebug' = 1 }  # adb local ligado
Set-LdJson (Join-Path $LdConfig 'leidians.config') @{ 'reduceAudio' = $false }

if ($Apk) {
    Write-Passo 'Ligando para instalar o app'
    Invoke-Ld launch --index $Indice | Out-Null
    Wait-LdPronto
    Write-Passo "Instalando $(Split-Path $Apk -Leaf)"
    Invoke-Adb install -r -g (Resolve-Path $Apk).Path
    if ($LASTEXITCODE -ne 0) { throw 'A instalacao falhou (veja a mensagem acima).' }
}

Write-Passo 'Pronto!'
Write-Host 'Ligar direto no YouCine:  .\ldplayer\iniciar.ps1'
Write-Host 'Ligar em outro app:       .\ldplayer\iniciar.ps1 -App com.pacote'
