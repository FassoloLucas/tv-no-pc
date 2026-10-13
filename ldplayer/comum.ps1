# Configuracao e funcoes compartilhadas pelos scripts do LDPlayer.
# Uso: . "$PSScriptRoot\comum.ps1"

# Reaproveita Write-Passo, Invoke-Nativo, Invoke-Adb e Wait-AndroidPronto do emulador
. "$PSScriptRoot\..\emulador\comum.ps1"

# --- O LDPlayer ----------------------------------------------------------------
$LdDir     = 'C:\LDPlayer'
$LdHome    = Join-Path $LdDir 'LDPlayer9'
$LdConsole = Join-Path $LdHome 'ldconsole.exe'
$LdConfig  = Join-Path $LdHome 'vms\config'
$Indice    = 0                 # primeira instancia do LDPlayer
$Serial    = 'emulator-5554'   # adb da instancia 0 (o mesmo do AVD "TV": nao ligue os dois juntos)
$AppPadrao = 'com.world.youcinetv'

# Instalador oficial (so baixa o pacote completo e instala)
$LdInstalador = 'https://setup.ldrescdn.com/download/LDPlayer9.exe?n=LDPlayer9_ens_1001_ld.exe'
$LdAssinante  = 'JUST OKAY LIMITED'   # empresa que assina o LDPlayer

# Hardware: 1080p deitado, como o AVD "TV"
$LdHardware = @('--resolution', '1920,1080,320', '--cpu', '4', '--memory', '2048')

# --- Funcoes ------------------------------------------------------------------
function Invoke-Ld {
    Invoke-Nativo $LdConsole @args
}

function Test-LdLigado {
    return ((Invoke-Ld isrunning --index $Indice | Out-String).Trim() -eq 'running')
}

function Stop-Ld([int]$TimeoutSeg = 60) {
    Invoke-Ld quit --index $Indice | Out-Null
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $limite -and (Get-Process -Name 'Ld9BoxHeadless' -ErrorAction SilentlyContinue)) {
        Start-Sleep -Seconds 1
    }
}

function Set-LdJson([string]$Arquivo, [hashtable]$Valores) {
    # Os .config do LDPlayer sao JSON; grava sem BOM, como o LDPlayer espera
    $json = Get-Content $Arquivo -Raw | ConvertFrom-Json
    foreach ($chave in $Valores.Keys) {
        $json | Add-Member -NotePropertyName $chave -NotePropertyValue $Valores[$chave] -Force
    }
    [IO.File]::WriteAllText($Arquivo, ($json | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
}

function Wait-LdPronto([int]$TimeoutSeg = 180) {
    # Como o Wait-AndroidPronto, mas: o adb tenta conectar no LDPlayer antes do Android
    # subir, a conexao fica "offline" e ele chega a levar 30 s+ para tentar de novo.
    # O "reconnect offline" forca a nova tentativa.
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $limite) {
        if (Test-EmuladorLigado) {
            $boot = (Invoke-Adb shell getprop sys.boot_completed 2>$null | Out-String).Trim()
            if ($boot -eq '1') { return }
        } else {
            Invoke-Nativo $Adb reconnect offline 2>$null | Out-Null
        }
        Start-Sleep -Milliseconds 700
    }
    throw "O Android nao terminou de ligar em $TimeoutSeg s."
}

function Test-AppNaFrente([string]$Pacote) {
    $frente = Invoke-Adb shell dumpsys activity activities 2>$null | Select-String 'mResumedActivity'
    return ("$frente" -match [regex]::Escape("$Pacote/"))
}

function Wait-App([string]$Pacote, [int]$TimeoutSeg = 180) {
    # Espera o app estar na frente da tela
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $limite) {
        if ((Test-EmuladorLigado) -and (Test-AppNaFrente $Pacote)) { return }
        Start-Sleep -Milliseconds 500
    }
    throw "O app $Pacote nao abriu em $TimeoutSeg s."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class JanelaLd {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public struct RECT { public int L, T, R, B; }
}
'@

function Get-JanelaLd {
    # A janela vem do "ldconsole list2" (indice,titulo,janela,...): quando o LDPlayer e ligado
    # por um processo sem janela (o servidor do controle), ela nasce oculta e o
    # MainWindowHandle do Get-Process fica zerado
    foreach ($linha in (Invoke-Ld list2)) {
        $campos = "$linha".Split(',')
        if ($campos.Count -gt 2 -and $campos[0] -eq "$Indice") { return [IntPtr][long]$campos[2] }
    }
    return [IntPtr]::Zero
}

function Wait-JanelaLd([int]$TimeoutSeg = 30) {
    $limite = (Get-Date).AddSeconds($TimeoutSeg)
    while ((Get-Date) -lt $limite) {
        if ((Get-JanelaLd) -ne [IntPtr]::Zero) { Start-Sleep -Seconds 1; return }
        Start-Sleep -Milliseconds 300
    }
}

function Enter-TelaCheia {
    # Mostra a janela do LDPlayer, traz para a frente e aperta F11 (tela cheia), se ainda nao estiver
    $janela = Get-JanelaLd
    if ($janela -eq [IntPtr]::Zero) { return }
    [JanelaLd]::ShowWindow($janela, 9) | Out-Null   # 9 = mostrar/restaurar, se estiver oculta ou minimizada
    # O Windows so deixa trazer uma janela para a frente quem recebeu o ultimo input;
    # rodando em segundo plano (pelo servidor do controle), um Alt "falso" libera isso
    [JanelaLd]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [JanelaLd]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [JanelaLd]::SetForegroundWindow($janela) | Out-Null
    Start-Sleep -Milliseconds 300
    if ([JanelaLd]::GetForegroundWindow() -ne $janela) { return }   # o F11 iria para outra janela

    $r = New-Object JanelaLd+RECT
    [JanelaLd]::GetWindowRect($janela, [ref]$r) | Out-Null
    $tela = [System.Windows.Forms.Screen]::FromHandle($janela).Bounds
    if (($r.R - $r.L) -lt $tela.Width -or ($r.B - $r.T) -lt $tela.Height) {
        [System.Windows.Forms.SendKeys]::SendWait('{F11}')
    }
}
