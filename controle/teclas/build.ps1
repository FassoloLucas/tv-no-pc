# Gera o teclas.dex: o programinha que o servidor roda no Android para apertar teclas
# que o teclado virtual do LDPlayer nao tem (como o OK de controle de TV, o DPAD_CENTER).
# O servidor copia o teclas.dex para o Android sozinho; so rode isto se mudar o Teclas.java.
#   .\build.ps1

$ErrorActionPreference = 'Stop'

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$bt = (Get-ChildItem (Join-Path $sdk 'build-tools') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$androidJar = Join-Path $sdk 'platforms\android-34\android.jar'
# (o java escreve isso no stderr; o cmd junta com o stdout para o PowerShell nao tratar como erro)
$javaHome = ((cmd /c 'java -XshowSettings:properties -version 2>&1' | Out-String) -split "`n" |
    Where-Object { $_ -match '^\s*java\.home = ' }) -replace '^\s*java\.home = ', '' | ForEach-Object Trim

$obra = Join-Path $PSScriptRoot 'obra'   # arquivos temporarios da montagem

function Rodar {
    # No PowerShell 5.1 um aviso no stderr de um programa vira erro fatal com 'Stop'
    $ErrorActionPreference = 'Continue'
    & $args[0] @($args | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) { throw "Falhou: $(Split-Path $args[0] -Leaf)" }
}

Remove-Item $obra -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$obra\classes", "$obra\dex" | Out-Null

Rodar (Join-Path $javaHome 'bin\javac.exe') -encoding UTF-8 -source 8 -target 8 '-Xlint:-options' `
    -bootclasspath $androidJar -d "$obra\classes" "$PSScriptRoot\Teclas.java"
# @(): com uma classe so, sem isso vira texto e o "@classes" abaixo quebra os argumentos
$classes = @(Get-ChildItem "$obra\classes" -Recurse -Filter *.class | ForEach-Object FullName)
Rodar "$bt\d8.bat" --release --min-api 19 --lib $androidJar --output "$obra\dex" @classes
Copy-Item "$obra\dex\classes.dex" (Join-Path $PSScriptRoot 'teclas.dex') -Force

Remove-Item $obra -Recurse -Force
Write-Host "Pronto: $(Join-Path $PSScriptRoot 'teclas.dex')" -ForegroundColor Green
