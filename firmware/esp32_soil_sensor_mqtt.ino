// ===================================================================
// ESP32-S3 - Capteur d'humidite du sol
// Mode Point d'Acces (AP) + reseau WiFi (STA) + MQTT (STEES)
//
// Garde l'interface web autonome (jauge + graphique temps reel),
// et EN PLUS publie la lecture sur le broker MQTT pour l'app STEES :
//   - tele/<DEVICE_ID>/SENSOR  -> {"soil_1": 42}
//   - tele/<DEVICE_ID>/STATE   -> {"POWER1":"OFF", ...}
//   - cmnd/<DEVICE_ID>/POWER1  -> ON/OFF/TOGGLE (pompe)
//   - stat/<DEVICE_ID>/RESULT  -> accusee de reception
//
// Librairies : WebServer (incluse) + PubSubClient (a installer :
// Gestionnaire de bibliotheques -> rechercher "PubSubClient").
// ===================================================================

#include <WiFi.h>
#include <WebServer.h>
#include <PubSubClient.h>

// ---------- A PERSONNALISER ----------
const char* AP_SSID = "SoilSensor-ESP32";
const char* AP_PASSWORD = "1234567890";   // minimum 8 caracteres, ou "" pour reseau ouvert

// Reseau WiFi avec internet (necessaire pour joindre le broker MQTT)
const char* WIFI_SSID = "VOTRE_RESEAU_WIFI";
const char* WIFI_PASS = "VOTRE_MOT_DE_PASSE";

// Broker MQTT (le meme que le backend STEES)
const char* MQTT_HOST = "broker.emqx.io";
const int   MQTT_PORT = 1883;

// ID a revendiquer dans l'app STEES (exactement ce nom)
const char* DEVICE_ID = "esp32_garden";

// ID du capteur a enregistrer dans l'app STEES (cle JSON du payload)
const char* SENSOR_ID = "soil_1";

// Pompe / relais optionnel sur POWER1. Mettre -1 si aucun relais.
const int PIN_RELAIS = 25;

const int PIN_CAPTEUR = 4;   // GPIO4 (ADC1)

// A CALIBRER :
const int VALEUR_SEC     = 3000;
const int VALEUR_MOUILLE = 1200;
// --------------------------------------

WebServer server(80);
WiFiClient espClient;
PubSubClient mqtt(espClient);

String sensorTopic = String("tele/") + DEVICE_ID + "/SENSOR";
String stateTopic  = String("tele/") + DEVICE_ID + "/STATE";
String statTopic   = String("stat/") + DEVICE_ID + "/RESULT";
String cmdSub      = String("cmnd/") + DEVICE_ID + "/#";

bool relay1 = false;
unsigned long lastPub = 0;

int lireHumidite() {
  int valeurBrute = analogRead(PIN_CAPTEUR);
  int pourcentage = map(valeurBrute, VALEUR_SEC, VALEUR_MOUILLE, 0, 100);
  pourcentage = constrain(pourcentage, 0, 100);
  return pourcentage;
}

// ---------- Page HTML principale ----------
const char PAGE_HTML[] PROGMEM = R"rawliteral(
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Capteur Humidite Sol</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body {
    font-family: 'Segoe UI', Arial, sans-serif;
    background: linear-gradient(135deg, #1a2a3a 0%, #0d1b2a 100%);
    color: #e8f1f2;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 24px 16px;
  }
  h1 {
    font-size: 1.4em;
    font-weight: 600;
    margin-bottom: 24px;
    letter-spacing: 0.5px;
    color: #7fdbda;
  }
  .card {
    background: rgba(255,255,255,0.05);
    border: 1px solid rgba(127,219,218,0.2);
    border-radius: 20px;
    padding: 24px;
    margin-bottom: 20px;
    width: 100%;
    max-width: 420px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.3);
    backdrop-filter: blur(10px);
  }
  #gaugeCanvas { display:block; margin: 0 auto; }
  .valeur-num {
    text-align: center;
    font-size: 3em;
    font-weight: 700;
    margin-top: -70px;
    color: #ffffff;
  }
  .valeur-label {
    text-align: center;
    font-size: 0.9em;
    color: #9fb8c8;
    margin-bottom: 10px;
  }
  .status {
    text-align: center;
    font-size: 0.95em;
    padding: 8px 16px;
    border-radius: 12px;
    display: inline-block;
    margin: 0 auto;
    font-weight: 600;
  }
  .status-wrap { text-align:center; }
  .sec { background: rgba(255,107,107,0.2); color: #ff6b6b; }
  .moyen { background: rgba(255,209,102,0.2); color: #ffd166; }
  .bon { background: rgba(6,214,160,0.2); color: #06d6a0; }
  canvas#chartCanvas {
    width: 100%;
    height: 160px;
    display: block;
  }
  .chart-title {
    font-size: 0.85em;
    color: #9fb8c8;
    margin-bottom: 8px;
  }
  .raw {
    text-align: center;
    font-size: 0.75em;
    color: #5f7a8a;
    margin-top: 12px;
  }
  .mqtt-status {
    text-align: center;
    font-size: 0.75em;
    margin-top: 6px;
  }
  .mqtt-ok { color: #06d6a0; }
  .mqtt-ko { color: #ff6b6b; }
  .pulse {
    animation: pulse 2s infinite;
  }
  @keyframes pulse {
    0%,100% { opacity: 1; }
    50% { opacity: 0.6; }
  }
</style>
</head>
<body>
  <h1>Humidite du Sol - Live</h1>

  <div class="card">
    <canvas id="gaugeCanvas" width="300" height="180"></canvas>
    <div class="valeur-num" id="valeurNum">--%</div>
    <div class="valeur-label">Taux d'humidite</div>
    <div class="status-wrap"><span class="status pulse" id="statusBadge">...</span></div>
    <div class="raw" id="rawValue">Valeur brute ADC: --</div>
    <div class="mqtt-status" id="mqttStatus">MQTT: ...</div>
  </div>

  <div class="card">
    <div class="chart-title">Historique (dernieres lectures)</div>
    <canvas id="chartCanvas"></canvas>
  </div>

<script>
const gaugeCanvas = document.getElementById('gaugeCanvas');
const gctx = gaugeCanvas.getContext('2d');
const chartCanvas = document.getElementById('chartCanvas');
const cctx = chartCanvas.getContext('2d');

function resizeChart() {
  chartCanvas.width = chartCanvas.clientWidth * 2;
  chartCanvas.height = chartCanvas.clientHeight * 2;
}
window.addEventListener('resize', resizeChart);
resizeChart();

let historique = [];

function couleurPour(valeur) {
  if (valeur < 30) return '#ff6b6b';
  if (valeur < 60) return '#ffd166';
  return '#06d6a0';
}

function dessinerJauge(valeur) {
  const cx = 150, cy = 150, r = 110;
  gctx.clearRect(0,0,300,180);

  gctx.beginPath();
  gctx.arc(cx, cy, r, Math.PI, 2*Math.PI);
  gctx.lineWidth = 18;
  gctx.strokeStyle = 'rgba(255,255,255,0.1)';
  gctx.lineCap = 'round';
  gctx.stroke();

  const angle = Math.PI + (valeur/100) * Math.PI;
  gctx.beginPath();
  gctx.arc(cx, cy, r, Math.PI, angle);
  gctx.lineWidth = 18;
  gctx.strokeStyle = couleurPour(valeur);
  gctx.lineCap = 'round';
  gctx.stroke();

  gctx.font = '11px Segoe UI';
  gctx.fillStyle = '#5f7a8a';
  gctx.fillText('0%', cx - r - 5, cy + 15);
  gctx.fillText('100%', cx + r - 20, cy + 15);
}

function dessinerGraphique() {
  const w = chartCanvas.width, h = chartCanvas.height;
  cctx.clearRect(0,0,w,h);

  if (historique.length < 2) return;

  cctx.strokeStyle = 'rgba(255,255,255,0.08)';
  cctx.lineWidth = 1;
  for (let i=0; i<=4; i++) {
    const y = (h/4)*i;
    cctx.beginPath();
    cctx.moveTo(0,y);
    cctx.lineTo(w,y);
    cctx.stroke();
  }

  const maxPoints = 60;
  const stepX = w / (maxPoints - 1);
  const startIdx = Math.max(0, historique.length - maxPoints);
  const points = historique.slice(startIdx);

  cctx.beginPath();
  points.forEach((v, i) => {
    const x = i * stepX;
    const y = h - (v/100) * h;
    if (i===0) cctx.moveTo(x,y); else cctx.lineTo(x,y);
  });

  const grad = cctx.createLinearGradient(0,0,0,h);
  grad.addColorStop(0, 'rgba(127,219,218,0.5)');
  grad.addColorStop(1, 'rgba(127,219,218,0.0)');

  cctx.lineTo((points.length-1)*stepX, h);
  cctx.lineTo(0, h);
  cctx.closePath();
  cctx.fillStyle = grad;
  cctx.fill();

  cctx.beginPath();
  points.forEach((v, i) => {
    const x = i * stepX;
    const y = h - (v/100) * h;
    if (i===0) cctx.moveTo(x,y); else cctx.lineTo(x,y);
  });
  cctx.strokeStyle = '#7fdbda';
  cctx.lineWidth = 3;
  cctx.stroke();
}

function majAffichage(data) {
  document.getElementById('valeurNum').textContent = data.humidity + '%';
  document.getElementById('rawValue').textContent = 'Valeur brute ADC: ' + data.raw;
  document.getElementById('mqttStatus').innerHTML = data.mqtt
    ? 'MQTT: <span class="mqtt-ok">connecte au broker</span>'
    : 'MQTT: <span class="mqtt-ko">non connecte (verifier le WiFi)</span>';

  const badge = document.getElementById('statusBadge');
  if (data.humidity < 30) {
    badge.textContent = 'Sol sec - Arrosage necessaire';
    badge.className = 'status pulse sec';
  } else if (data.humidity < 60) {
    badge.textContent = 'Humidite moyenne';
    badge.className = 'status moyen';
  } else {
    badge.textContent = 'Sol bien humide';
    badge.className = 'status bon';
  }

  dessinerJauge(data.humidity);

  historique.push(data.humidity);
  if (historique.length > 60) historique.shift();
  dessinerGraphique();
}

function rafraichir() {
  fetch('/data')
    .then(r => r.json())
    .then(majAffichage)
    .catch(e => console.error('Erreur fetch:', e));
}

dessinerJauge(0);
rafraichir();
setInterval(rafraichir, 2000);
</script>
</body>
</html>
)rawliteral";

// ---------- Handlers du serveur web ----------
void handleRoot() {
  server.send_P(200, "text/html", PAGE_HTML);
}

void handleData() {
  int humidite = lireHumidite();
  int brute = analogRead(PIN_CAPTEUR);

  String json = "{\"humidity\":" + String(humidite) + ",\"raw\":" + String(brute) +
                ",\"mqtt\":" + (mqtt.connected() ? "true" : "false") + "}";
  server.send(200, "application/json", json);
}

// ---------- MQTT ----------
void reconnectMQTT() {
  while (!mqtt.connected()) {
    if (WiFi.status() == WL_CONNECTED) {
      Serial.print("Connexion MQTT... ");
      if (mqtt.connect(DEVICE_ID)) {
        Serial.println("OK");
        mqtt.subscribe(cmdSub.c_str());
      } else {
        Serial.print("echec, rc=");
        Serial.println(mqtt.state());
        delay(2000);
      }
    } else {
      delay(1000);
    }
  }
}

void callback(char* topic, byte* payload, unsigned int len) {
  String t = String(topic);
  String msg = String((char*)payload).substring(0, len);
  msg.trim();
  String up; for (char c : msg) up += toupper(c);

  if (PIN_RELAIS < 0) return;

  String suffix = t.substring(String("cmnd/").length() + strlen(DEVICE_ID) + 1);
  if (!suffix.startsWith("POWER")) return;
  int ch = suffix.substring(5).toInt();
  if (ch != 1) return;

  if (up == "ON") relay1 = true;
  else if (up == "OFF") relay1 = false;
  else if (up == "TOGGLE") relay1 = !relay1;
  digitalWrite(PIN_RELAIS, relay1 ? HIGH : LOW);
  Serial.printf("Relais 1 -> %s\n", relay1 ? "ON" : "OFF");

  String ack = String("{\"POWER1\":\"") + (relay1 ? "ON" : "OFF") + "\"}";
  mqtt.publish(statTopic.c_str(), ack.c_str());
}

void publierMQTT() {
  int humidite = lireHumidite();

  String sensor = String("{\"Time\":\"x\",\"") + SENSOR_ID + "\":" + humidite + "}";
  mqtt.publish(sensorTopic.c_str(), sensor.c_str());

  String state = String("{\"POWER1\":\"") + (relay1 ? "ON" : "OFF") +
                 "\",\"POWER2\":\"OFF\",\"POWER3\":\"OFF\",\"POWER4\":\"OFF\"}";
  mqtt.publish(stateTopic.c_str(), state.c_str());

  Serial.printf("MQTT -> %s=%d%%\n", SENSOR_ID, humidite);
}

void setup() {
  Serial.begin(115200);
  delay(500);

  analogReadResolution(12);
  if (PIN_RELAIS >= 0) pinMode(PIN_RELAIS, OUTPUT);

  Serial.println();
  Serial.println("Demarrage du point d'acces + WiFi...");

  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(AP_SSID, AP_PASSWORD);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  IPAddress ip = WiFi.softAPIP();
  Serial.print("Point d'acces cree : ");
  Serial.println(AP_SSID);
  Serial.print("Adresse IP : ");
  Serial.println(ip);
  Serial.println("Connecte-toi au Wi-Fi ci-dessus, puis ouvre cette IP dans un navigateur");

  server.on("/", handleRoot);
  server.on("/data", handleData);
  server.begin();
  Serial.println("Serveur web demarre !");

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setCallback(callback);
}

void loop() {
  server.handleClient();

  if (WiFi.status() == WL_CONNECTED && !mqtt.connected()) reconnectMQTT();
  if (mqtt.connected()) mqtt.loop();

  if (millis() - lastPub > 10000) {
    lastPub = millis();
    if (mqtt.connected()) publierMQTT();
  }
}
