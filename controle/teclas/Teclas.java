import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;

// Aperta teclas do Android (qualquer KEYCODE_*) pelo InputManager, igual ao "input keyevent",
// mas fica rodando: so a primeira tecla paga a partida do Java (~0,8 s), as outras sao imediatas.
// Serve para as teclas que o teclado virtual do LDPlayer nao tem, como o DPAD_CENTER
// (o "OK" do controle de TV, unico que pausa o player do YouCine).
//
// Roda no Android pelo adb:  CLASSPATH=/data/local/tmp/teclas.dex app_process / Teclas
// Le um codigo de tecla por linha e responde "ok" (ou "erro ...") a cada uma.
public class Teclas {
    // InputManager.INJECT_INPUT_EVENT_MODE_ASYNC: entrega sem esperar o app terminar de tratar
    private static final int ASSINCRONO = 0;

    public static void main(String[] args) throws Exception {
        // getInstance e injectInputEvent sao escondidos (@hide) no SDK, dai a reflexao
        Class<?> classe = Class.forName("android.hardware.input.InputManager");
        Object gerente = classe.getMethod("getInstance").invoke(null);
        Method injetar = classe.getMethod("injectInputEvent", InputEvent.class, int.class);

        BufferedReader entrada = new BufferedReader(new InputStreamReader(System.in));
        responder("pronto");
        String linha;
        while ((linha = entrada.readLine()) != null) {
            linha = linha.trim();
            if (linha.isEmpty()) continue;
            try {
                int codigo = Integer.parseInt(linha);
                long agora = SystemClock.uptimeMillis();
                boolean desceu = (Boolean) injetar.invoke(gerente, tecla(agora, KeyEvent.ACTION_DOWN, codigo), ASSINCRONO);
                boolean subiu = (Boolean) injetar.invoke(gerente, tecla(agora, KeyEvent.ACTION_UP, codigo), ASSINCRONO);
                responder(desceu && subiu ? "ok" : "erro o Android recusou a tecla " + codigo);
            } catch (Exception e) {
                responder("erro " + e);
            }
        }
    }

    private static KeyEvent tecla(long hora, int acao, int codigo) {
        return new KeyEvent(hora, hora, acao, codigo, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                InputDevice.SOURCE_KEYBOARD);
    }

    private static void responder(String texto) {
        System.out.println(texto);
        System.out.flush();
    }
}
