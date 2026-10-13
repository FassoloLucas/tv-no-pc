# Gera o app Android "TV" (controle-tv.apk), que abre o controle em tela cheia.
# Nao precisa de Android Studio: usa o JDK e o Android SDK direto.
# O APK vai para controle\public, entao o celular baixa em http://<ip-do-pc>:8765/controle-tv.apk
#   .\build.ps1

$ErrorActionPreference = 'Stop'

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
$bt = (Get-ChildItem (Join-Path $sdk 'build-tools') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$androidJar = Join-Path $sdk 'platforms\android-34\android.jar'
# (o java escreve isso no stderr; o cmd junta com o stdout para o PowerShell nao tratar como erro)
$javaHome = ((cmd /c 'java -XshowSettings:properties -version 2>&1' | Out-String) -split "`n" |
    Where-Object { $_ -match '^\s*java\.home = ' }) -replace '^\s*java\.home = ', '' | ForEach-Object Trim
$keytool = Join-Path $javaHome 'bin\keytool.exe'

$obra  = Join-Path $PSScriptRoot 'obra'                       # arquivos temporarios da montagem
$saida = Join-Path $PSScriptRoot '..\public\controle-tv.apk'
$chave = Join-Path $PSScriptRoot 'assinatura.jks'             # mesma chave sempre, para o app poder ser atualizado
$senha = $env:TV_KEYSTORE_PASSWORD
if (-not $senha) { throw 'Defina TV_KEYSTORE_PASSWORD antes de gerar o app.' }
$versao = [int](Get-Date -Format 'yyMMddHH')                  # cresce a cada montagem (o Android exige)

function Rodar {
    # No PowerShell 5.1 um aviso no stderr de um programa vira erro fatal com 'Stop'
    $ErrorActionPreference = 'Continue'
    & $args[0] @($args | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) { throw "Falhou: $(Split-Path $args[0] -Leaf)" }
}

Remove-Item $obra -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$obra\classes", "$obra\dex", "$obra\gen" | Out-Null

Write-Host '==> Recursos (icone, manifesto)'
Rodar "$bt\aapt2.exe" compile --dir "$PSScriptRoot\res" -o "$obra\res.zip"
Rodar "$bt\aapt2.exe" link -o "$obra\base.apk" -I $androidJar --manifest "$PSScriptRoot\AndroidManifest.xml" `
    --min-sdk-version 23 --target-sdk-version 34 --version-code $versao --version-name "1.$versao" `
    --java "$obra\gen" "$obra\res.zip"

Write-Host '==> Codigo'
$fontes = Get-ChildItem "$PSScriptRoot\src", "$obra\gen" -Recurse -Filter *.java | ForEach-Object FullName
# core-lambda-stubs: o android.jar nao tem as classes que os lambdas do Java 8 usam
Rodar (Join-Path $javaHome 'bin\javac.exe') -encoding UTF-8 -source 8 -target 8 '-Xlint:-options' `
    -bootclasspath "$androidJar;$bt\core-lambda-stubs.jar" -d "$obra\classes" @fontes
$classes = Get-ChildItem "$obra\classes" -Recurse -Filter *.class | ForEach-Object FullName
Rodar "$bt\d8.bat" --release --min-api 23 --lib $androidJar --output "$obra\dex" @classes

Write-Host '==> Empacotando e assinando'
Push-Location "$obra\dex"
try { Rodar "$bt\aapt.exe" add "$obra\base.apk" classes.dex } finally { Pop-Location }
Rodar "$bt\zipalign.exe" -f -p 4 "$obra\base.apk" "$obra\alinhado.apk"
if (-not (Test-Path $chave)) {
    Rodar $keytool -genkeypair -keystore $chave -alias tv -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass $senha -keypass $senha -dname 'CN=Controle da TV'
}
Rodar "$bt\apksigner.bat" sign --ks $chave --ks-pass "pass:$senha" --out $saida "$obra\alinhado.apk"
Rodar "$bt\apksigner.bat" verify $saida

Remove-Item $obra -Recurse -Force
Write-Host "Pronto: $((Resolve-Path $saida).Path) (versao $versao)" -ForegroundColor Green
