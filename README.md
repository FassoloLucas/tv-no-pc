# TV no PC

Transforme o PC em uma TV box com YouCine no LDPlayer 9 e use o celular como controle remoto. Este projeto independente fornece o controle e os scripts de configuração; não tem afiliação com LDPlayer ou YouCine e não distribui esses aplicativos.

## Como funciona

Celular (navegador ou app Android TV) → HTTP pela rede Wi-Fi → servidor Node no Windows → ADB → LDPlayer. O servidor usa apenas módulos nativos do Node, sem npm install. Uma sessão ADB persistente envia teclado e mouse; um auxiliar Java envia DPAD_CENTER, o OK de controle de TV. O app do celular usa WebView e descobre o PC por broadcast UDP na porta 8765.

Recursos: ligar/fechar LDPlayer, abrir YouCine em tela cheia sem reiniciar o app que já está na frente, setas com repetição, OK, voltar, início, volume, pausa, episódio anterior/próximo, touchpad com clique/rolagem e digitação. A troca de episódios lê a interface do YouCine com dumpsys e navega pelo foco.

## Pré-requisitos

- PC Windows com PowerShell, virtualização habilitada e condições de executar LDPlayer 9.
- Git e Node.js disponíveis no PATH; não há dependências npm.
- Android SDK Platform-Tools (adb.exe) em `%LOCALAPPDATA%\Android\Sdk\platform-tools`. O servidor usa esse caminho diretamente; ajuste `controle/servidor.js` se seu SDK estiver em outro local.
- Para gerar os auxiliares: JDK com java, javac e keytool; Android SDK Build-Tools e plataforma android-34. Os scripts de build aceitam ANDROID_HOME; caso contrário usam o SDK local indicado acima.
- Celular na mesma rede local. Navegador para o controle; Android 6.0 ou superior para o app próprio.
- Aplicativo de TV obtido e instalado separadamente, de uma fonte autorizada. APKs de terceiros não estão neste repositório.

## Instalação no PC

Execute os comandos na raiz do projeto:

```powershell
git clone https://github.com/FassoloLucas/tv-no-pc.git
cd tv-no-pc
.\ldplayer\setup.ps1
```

O setup baixa o instalador, verifica a assinatura esperada no código, instala em `C:\LDPlayer`, configura a instância 0 em 1920×1080, quatro núcleos e 2048 MB de RAM, e habilita ADB local. Ele fecha a instância ao aplicar configurações. Se já houver instalação nesse caminho, ela é reutilizada. Para instalar também um APK que você já possui:

```powershell
.\ldplayer\setup.ps1 -Apk 'C:\caminho\seu-app.apk'
```

O app padrão é `com.world.youcinetv`, configurado em `ldplayer/comum.ps1`. O servidor também tem lógica específica para esse pacote; para adaptar a outro aplicativo, revise `controle/servidor.js`. Para abrir outro pacote manualmente:

```powershell
.\ldplayer\iniciar.ps1 -App com.exemplo.app
```

Gere o auxiliar de teclas antes de usar o controle (o DEX não é versionado):

```powershell
.\controle\teclas\build.ps1
.\controle\liberar-firewall.ps1
node .\controle\servidor.js
```

O script de firewall pede elevação e libera TCP 8765 apenas no perfil privado. O terminal mostra o endereço do PC. Não execute o AVD oficial e o LDPlayer simultaneamente: ambos usam `emulator-5554`.

## Celular

Abra `http://<IP-DO-PC>:8765` no navegador. Toque em TV para ligar o emulador e abrir o app. A reprodução fica no PC; o celular envia comandos, sem receber transmissão de vídeo.

Para usar o app Android próprio, gere seu APK com uma senha de assinatura escolhida por você:

```powershell
$segura = Read-Host 'Senha da chave de assinatura' -AsSecureString
$env:TV_KEYSTORE_PASSWORD = [System.Net.NetworkCredential]::new('', $segura).Password
.\controle\app\build.ps1
Remove-Item Env:TV_KEYSTORE_PASSWORD
```

Depois abra o controle no celular e toque em Baixar o app TV, ou acesse `http://<IP-DO-PC>:8765/controle-tv.apk`. Instale o arquivo permitindo a instalação por essa fonte. APKs e chaves são gerados localmente e ignorados pelo Git. Guarde `controle/app/assinatura.jks` e sua senha em local seguro: atualizações precisam da mesma chave. A chave original do autor não é distribuída, portanto seu APK não atualiza uma instalação assinada por ela.

O app tenta o endereço salvo e depois procura o PC por UDP 8765. A configuração inicial usa loopback como valor neutro, sem IP residencial: a descoberta ou a opção Mudar endereço define o PC correto. O script de firewall existente libera apenas TCP; para descoberta automática, permita também UDP 8765 no perfil privado nas configurações do Firewall do Windows. O endereço manual funciona sem descoberta.

## Inicialização automática e configuração

```powershell
.\controle\iniciar-com-windows.ps1
# Para remover a inicialização automática:
.\controle\iniciar-com-windows.ps1 -Remover
```

Esse script inicia o servidor oculto ao entrar no Windows e o reinicia após queda; grava saída em `controle/servidor.log`. Para outra porta no servidor manual:

```powershell
$env:PORTA = '9000'
node .\controle\servidor.js
```

Ajuste a regra de firewall com `-Porta 9000`. O app Android procura por UDP na porta fixa 8765; se mudar a porta, use endereço manual ou adapte a constante PORTA no código Java.

## Limitações e solução de problemas

- Use apenas rede local confiável: o servidor escuta em todas as interfaces e não implementa login ou HTTPS. Não encaminhe a porta para a internet.
- PC não encontrado: confirme mesmo Wi-Fi, IP, servidor ativo, perfil privado do Windows e firewall. Redes de convidados podem bloquear comunicação entre dispositivos.
- ADB indisponível: confirme o caminho do SDK, instância 0, ADB local habilitado e ausência de outro emulador com o mesmo serial. `adb devices -l` ajuda a conferir os dispositivos quando você executar o projeto.
- OK falha: gere `controle/teclas/teclas.dex`; o servidor o envia automaticamente ao Android.
- Build falha: confirme plataforma android-34, Build-Tools e JDK no PATH. Os scripts escolhem a pasta de Build-Tools pelo nome em ordem decrescente.
- Troca de episódio exige um episódio aberto em tela cheia no YouCine. Mudanças na interface do aplicativo podem exigir adaptação do código.
- A digitação remove acentos devido ao caminho usado pelo ADB. O mecanismo de entrada depende dos dispositivos virtuais e permissões específicas do LDPlayer.
- Os scripts em `emulador/` configuram um AVD Android oficial alternativo; não são o caminho principal para o controle LDPlayer. Seu setup exige Android SDK Command-line Tools e baixa a imagem Android 11.

## Conteúdo e validação

Inclui código próprio, scripts, ícones e documentação. Não inclui instaladores/aplicativos de terceiros, APKs, DEX, chaves de assinatura, senhas, logs, caches ou configuração residencial. A publicação foi preparada em uma cópia separada, sem alterar o projeto original. A revisão foi estática; nenhum build, servidor ou emulador foi executado para validar esta versão.
