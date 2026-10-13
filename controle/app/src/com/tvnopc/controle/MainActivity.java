package com.tvnopc.controle;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;

// App "TV": abre o controle remoto (servidor no PC) em tela cheia.
// Antes de abrir, confere se o PC responde no endereco salvo; se nao, procura por
// ele na rede (o servidor responde a um "tv?" em broadcast UDP) e, se nao achar,
// deixa tentar de novo ou digitar o endereco.
public class MainActivity extends Activity {
    private static final String PADRAO = "http://127.0.0.1:8765/";
    private static final int PORTA = 8765;
    private static final int FUNDO = 0xFF121418;
    private static final String TELA_PROCURANDO =
            "<body style='margin:0;height:100vh;display:flex;align-items:center;justify-content:center;"
                    + "background:#121418;color:#9298a3;font:18px sans-serif'>Procurando o PC...</body>";

    private WebView web;
    private SharedPreferences prefs;
    private boolean procurando;

    @Override
    protected void onCreate(Bundle estado) {
        super.onCreate(estado);
        getWindow().setStatusBarColor(FUNDO);
        getWindow().setNavigationBarColor(FUNDO);
        prefs = getSharedPreferences("controle", MODE_PRIVATE);

        web = new WebView(this);
        web.setBackgroundColor(FUNDO);
        WebSettings ajustes = web.getSettings();
        ajustes.setJavaScriptEnabled(true);
        ajustes.setDomStorageEnabled(true);
        // A pagina ve "ControleTV-App" e nao registra o service worker (o app cuida do "sem conexao")
        ajustes.setUserAgentString(ajustes.getUserAgentString() + " ControleTV-App");
        web.setWebChromeClient(new WebChromeClient()); // mostra o confirm() do botao Desligar
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedError(WebView v, WebResourceRequest pedido, WebResourceError erro) {
                if (pedido.isForMainFrame()) conectar();
            }
        });
        setContentView(web);
        conectar();
    }

    private String endereco() {
        return prefs.getString("endereco", PADRAO);
    }

    private void abrir(String url) {
        prefs.edit().putString("endereco", url).apply();
        web.loadUrl(url);
    }

    // Confere o endereco salvo; se o PC nao responder, procura na rede
    private void conectar() {
        if (procurando) return;
        procurando = true;
        web.loadDataWithBaseURL(null, TELA_PROCURANDO, "text/html", "utf-8", null);
        String salvo = endereco();
        new Thread(() -> {
            String certo = responde(salvo) ? salvo : null;
            if (certo == null) {
                String achado = descobrir(); // o IP do PC pode ter mudado
                if (achado != null && responde(achado)) certo = achado;
            }
            String fim = certo;
            runOnUiThread(() -> {
                procurando = false;
                if (fim != null) abrir(fim);
                else naoAchou();
            });
        }).start();
    }

    private static boolean responde(String url) {
        try {
            HttpURLConnection c = (HttpURLConnection) new URL(url + "api/estado").openConnection();
            c.setConnectTimeout(1500);
            c.setReadTimeout(3000);
            boolean ok = c.getResponseCode() == 200;
            c.disconnect();
            return ok;
        } catch (Exception e) {
            return false;
        }
    }

    private static String descobrir() {
        try (DatagramSocket s = new DatagramSocket()) {
            s.setBroadcast(true);
            s.setSoTimeout(2000);
            byte[] pergunta = "tv?".getBytes("UTF-8");
            s.send(new DatagramPacket(pergunta, pergunta.length, InetAddress.getByName("255.255.255.255"), PORTA));
            byte[] buf = new byte[32];
            DatagramPacket resposta = new DatagramPacket(buf, buf.length);
            s.receive(resposta);
            String porta = new String(resposta.getData(), 0, resposta.getLength(), "UTF-8").trim();
            return "http://" + resposta.getAddress().getHostAddress() + ":" + porta + "/";
        } catch (Exception e) {
            return null;
        }
    }

    private void naoAchou() {
        new AlertDialog.Builder(this)
                .setTitle("PC não encontrado")
                .setMessage("Confira se o PC está ligado e se o celular está no mesmo Wi-Fi.\n\nEndereço: " + endereco())
                .setPositiveButton("Tentar de novo", (d, b) -> conectar())
                .setNeutralButton("Mudar endereço", (d, b) -> mudarEndereco())
                .setCancelable(false)
                .show();
    }

    private void mudarEndereco() {
        EditText campo = new EditText(this);
        campo.setText(endereco());
        new AlertDialog.Builder(this)
                .setTitle("Endereço do PC")
                .setView(campo)
                .setPositiveButton("Abrir", (d, b) -> {
                    String url = campo.getText().toString().trim();
                    if (!url.startsWith("http")) url = "http://" + url;
                    if (!url.endsWith("/")) url += "/";
                    prefs.edit().putString("endereco", url).apply();
                    conectar();
                })
                .setNegativeButton("Cancelar", (d, b) -> naoAchou())
                .setCancelable(false)
                .show();
    }
}
