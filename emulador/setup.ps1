# Prepara o "TV": baixa a imagem do Android, cria o AVD e faz o primeiro boot.
# Pode rodar de novo sem problema. Use -Recriar para apagar o AVD e criar do zero.
param([switch]$Recriar)

. "$PSScriptRoot\comum.ps1"

Write-Passo "SDK em $SdkRoot"
if (-not (Test-Path $AndroidCli)) {
    throw "Nao achei o Android CLI em $AndroidCli. Instale/atualize o 'Android SDK Command-line Tools' (https://developer.android.com/studio#command-line-tools-only) nessa pasta."
}
if (-not $env:JAVA_HOME -and -not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw 'O avdmanager precisa do Java 17 ou mais novo instalado.'
}
if (Test-EmuladorLigado) {
    throw 'Feche o emulador antes de rodar o setup.'
}

# Instala so o que falta (nao atualiza o que ja existe)
$pacotes = [ordered]@{
    'platform-tools'              = $Adb
    'emulator'                    = $Emulator
    ($ImagePkg -replace ';', '/') = Join-Path $ImageDir 'system.img'
}
$faltando = @($pacotes.Keys | Where-Object { -not (Test-Path $pacotes[$_]) })
if ($faltando) {
    Write-Passo "Instalando $($faltando -join ', ') (a imagem do Android tem ~1,4 GB)"
    Invoke-Nativo $AndroidCli sdk install @faltando
    # O android.exe as vezes fecha com erro no Windows 10 mesmo tendo instalado
    # tudo, entao conferimos os arquivos em vez do codigo de saida
    $faltando = @($pacotes.Keys | Where-Object { -not (Test-Path $pacotes[$_]) })
    if ($faltando) { throw "Nao consegui instalar: $($faltando -join ', ') (veja a mensagem acima)." }
} else {
    Write-Passo 'Emulador, adb e imagem do Android ja instalados'
}

Write-Passo "Criando o AVD '$AvdName'"
if ($Recriar -and (Test-Path $AvdDir)) {
    Invoke-Nativo $AvdManager delete avd -n $AvdName
}
if (Test-Path $AvdConfig) {
    Write-Host 'AVD ja existe, so atualizando a configuracao.'
} else {
    'no' | Invoke-Nativo $AvdManager create avd -n $AvdName -k $ImagePkg --force
    if ($LASTEXITCODE -ne 0) { throw 'O avdmanager falhou (veja a mensagem acima).' }
}

Write-Passo 'Aplicando o hardware do TV no config.ini'
$config = [ordered]@{}
foreach ($linha in Get-Content $AvdConfig) {
    if ($linha -notmatch '=') { continue }
    $chave, $valor = $linha -split '=', 2
    $config[$chave.Trim()] = $valor.Trim()
}
foreach ($chave in $AvdHardware.Keys) { $config[$chave] = $AvdHardware[$chave] }
$config.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content $AvdConfig -Encoding ASCII

Write-Passo 'Boot completo (pode levar alguns minutos)'
Start-Emulador -ColdBoot
Wait-AndroidPronto -TimeoutSeg 600

Write-Passo 'Ajustando o Android para funcionar como TV'
Invoke-Adb shell settings put system screen_off_timeout 2147483647  # tela nunca apaga
Invoke-Adb shell svc power stayon true
Invoke-Adb shell locksettings set-disabled true | Out-Null         # sem tela de bloqueio
Invoke-Adb shell settings put system time_12_24 24

# O idioma precisa de root (a imagem google_apis permite) e de um reboot.
# (O fuso vem do parametro -timezone ao ligar o emulador.)
Invoke-Adb root | Out-Null
Invoke-Adb wait-for-device
Invoke-Adb shell setprop persist.sys.locale $Idioma
Invoke-Adb reboot
Invoke-Adb wait-for-disconnect
Wait-AndroidPronto -TimeoutSeg 600

$abis = (Invoke-Adb shell getprop ro.product.cpu.abilist | Out-String).Trim()
Write-Host "Arquiteturas suportadas: $abis"
if ($abis -notmatch 'arm') {
    Write-Warning 'Esta imagem nao roda apps ARM; a maioria dos apps de IPTV nao vai instalar.'
}

Write-Passo 'Desligando e salvando o snapshot do quick boot'
Stop-Emulador
if (Test-Path (Join-Path $AvdDir 'snapshots\default_boot\snapshot.pb')) {
    Write-Host 'Snapshot salvo: os proximos boots levam poucos segundos.' -ForegroundColor Green
} else {
    Write-Warning 'O snapshot nao foi salvo; o proximo boot sera completo (mais lento).'
}

Write-Passo 'Pronto!'
Write-Host 'Ligar o TV:          .\emulador\iniciar.ps1'
Write-Host 'Instalar um APK:     .\emulador\instalar-apk.ps1 caminho\do\app.apk'
