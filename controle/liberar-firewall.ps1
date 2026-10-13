# Libera a porta do controle no Firewall do Windows, so na rede privada (a de casa).
# Sem isso o celular nao consegue abrir a pagina. Pede permissao de administrador.
#   .\liberar-firewall.ps1               -> porta 8765
#   .\liberar-firewall.ps1 -Porta 9000
param([int]$Porta = 8765)

$ErrorActionPreference = 'Stop'
$nome = "Controle da TV (porta $Porta)"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    # Abre a si mesmo como administrador (o Windows mostra o aviso de permissao)
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Porta', $Porta)
    if ($p.ExitCode -ne 0) { throw 'Nao consegui criar a regra no firewall.' }
} else {
    Get-NetFirewallRule -DisplayName $nome -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $nome -Direction Inbound -Protocol TCP -LocalPort $Porta -Action Allow -Profile Private | Out-Null
}

Get-NetFirewallRule -DisplayName $nome | Select-Object DisplayName, Profile, Action, Enabled
