# Configuracao e funcoes compartilhadas pelos scripts do emulador.
# Uso: . "$PSScriptRoot\comum.ps1"

$ErrorActionPreference = 'Stop'

# --- O "TV" -------------------------------------------------------------------
$AvdName  = 'TV'
$ApiLevel = 30   # Android 11: a partir dele a imagem x86_64 roda apps ARM (traducao)
$ImagePkg = "system-images;android-$ApiLevel;google_apis;x86_64"
$Port     = 5554 # porta fixa -> serial previsivel para o adb
$Serial   = "emulator-$Port"
$Idioma   = 'pt-BR'
$Fuso     = 'America/Sao_Paulo'

# Hardware: 1080p em paisagem, enxuto em RAM/CPU, video pela GPU do PC
$AvdHardware = [ordered]@{
    'hw.lcd.width'            = '1920'
    'hw.lcd.height'           = '1080'
    'hw.lcd.density'          = '320'   # mesma densidade de uma Android TV 1080p
    'hw.initialOrientation'   = 'landscape'
    'hw.ramSize'              = '2048'
    'vm.heapSize'             = '256M'  # memoria por app (o padrao, 32M, e pouco para video)
    'hw.cpu.ncore'            = '4'
    'hw.gpu.enabled'          = 'yes'
    'hw.gpu.mode'             = 'host'
    'hw.keyboard'             = 'yes'   # teclado do PC funciona dentro do Android
    'hw.dPad'                 = 'yes'
    'hw.mainKeys'             = 'yes'   # sem a barra de botoes na tela (voltar/home vem do controle)
    'hw.audioInput'           = 'no'
    'hw.camera.back'          = 'none'
    'hw.camera.front'         = 'none'
    'hw.gps'                  = 'no'
    'hw.accelerometer'        = 'no'    # sem sensor de rotacao: fica sempre deitado
    'hw.sensors.orientation'  = 'no'
    'hw.sensors.proximity'    = 'no'
    'disk.dataPartition.size' = '6G'
    'skin.dynamic'            = 'yes'
    'skin.name'               = '1920x1080'
    'skin.path'               = '_no_skin'
    'showDeviceFrame'         = 'no'
    'fastboot.forceColdBoot'  = 'no'
    'fastboot.forceFastBoot'  = 'yes'   # liga a partir do snapshot (poucos segundos)
}

# --- Caminhos do SDK ----------------------------------------------------------
$SdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME }
           elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT }
           else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$AvdHome = if ($env:ANDROID_AVD_HOME) { $env:ANDROID_AVD_HOME }
           else { Join-Path $env:USERPROFILE '.android\avd' }

$AndroidCli = Join-Path $SdkRoot 'cmdline-tools\latest\bin\android.exe'  # substituto do sdkmanager
$AvdManager = Join-Path $SdkRoot 'cmdline-tools\latest\bin\avdmanager.bat'
$ImageDir   = Join-Path $SdkRoot ($ImagePkg -replace ';', '\')
$Emulator   = Join-Path $SdkRoot 'emulator\emulator.exe'
$Adb        = Join-Path $SdkRoot 'platform-tools\adb.exe'
$AvdDir     = Join-Path $AvdHome "$AvdName.avd"
$AvdConfig  = Join-Path $AvdDir 'config.ini'

# --- Funcoes ------------------------------------------------------------------
function Write-Passo([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

function Invoke-Nativo {
    # Roda um programa externo. No PowerShell 5.1, um simples aviso no stderr vira
    # erro fatal quando $ErrorActionPreference = 'Stop'; aqui usamos 'Continue'
    # e quem chama confere o $LASTEXITCODE.
    $ErrorActionPreference = 'Continue'
    $programa = $args[0]
    $resto = @($args | Select-Object -Skip 1)   # @(): com um so argumento, continua sendo lista
    if (-not $MyInvocation.ExpectingInput) { & $programa @resto; return }

    # O PowerShell 5.1 manda o texto usando [Console]::InputEncoding; se ela for
    # UTF-8 com BOM, o programa recebe lixo no inicio ("?no" em vez de "no")
    $encodingOriginal = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
        $input | & $programa @resto
    } finally {
        [Console]::InputEncoding = $encodingOriginal
    }
}

function Invoke-Adb {
    # adb sempre apontando para o nosso emulador
    Invoke-Nativo $Adb -s $Serial @args
}

function Test-EmuladorLigado {
    $estado = Invoke-Adb get-state 2>$null
    return ($LASTEXITCODE -eq 0 -and $estado -eq 'device')
}

function Start-Emulador([switch]$ColdBoot) {
    $emuArgs = @('-avd', $AvdName, '-port', $Port, '-timezone', $Fuso, '-no-boot-anim', '-gpu', 'host', '-netfast', '-no-metrics')
    if ($ColdBoot) { $emuArgs += '-no-snapshot-load' }
    Start-Process -FilePath $Emulator -ArgumentList $emuArgs | Out-Null
}

function Wait-AndroidPronto([int]$TimeoutSeg = 300) {
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $limite) {
        if (Test-EmuladorLigado) {
            $boot = (Invoke-Adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
            if ($boot -eq '1') { return }
        }
        Start-Sleep -Seconds 2
    }
    throw "O Android nao terminou de ligar em $TimeoutSeg s."
}

function Start-App([string]$Pacote, [int]$TimeoutSeg = 20) {
    # Logo depois do boot o gerenciador de pacotes ainda pode nao responder; tenta de novo ate o limite
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    do {
        # Apps de TV box abrem pela categoria LEANBACK; apps de celular, pela LAUNCHER
        foreach ($categoria in 'android.intent.category.LEANBACK_LAUNCHER', 'android.intent.category.LAUNCHER') {
            $atividade = Invoke-Adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c $categoria $Pacote |
                Select-Object -Last 1
            if ("$atividade".Trim() -match '^\S+/\S+$') {
                # Abre como o icone do launcher (MAIN + categoria, NEW_TASK|RESET_TASK_IF_NEEDED):
                # se o app ja estiver aberto, so volta para ele em vez de abrir a tela inicial de novo
                Invoke-Adb shell am start -a android.intent.action.MAIN -c $categoria -f 0x10200000 -n "$atividade".Trim() | Out-Null
                return
            }
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $limite)
    throw "Nao achei a tela inicial do app $Pacote (ele esta instalado?)."
}

function Stop-Emulador([int]$TimeoutSeg = 120) {
    # 'emu kill' fecha de forma limpa e grava o snapshot do quick boot
    Invoke-Adb emu kill | Out-Null
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $limite -and (Get-Process -Name 'qemu-system-x86_64*' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 2
    }
}
