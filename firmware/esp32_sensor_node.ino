#include <WiFi.h>
#include <PubSubClient.h>

const char* WIFI_SSID = "your-wifi";
const char* WIFI_PASSWORD = "your-password";

const char* MQTT_HOST = "broker.emqx.io";
const int   MQTT_PORT = 1883;
const char* MQTT_USER = "";
const char* MQTT_PASS = "";

const char* DEVICE_ID = "esp32_sensor_01";

const char* SENSOR_ID = "soil_1";

const int SENSOR_PIN = 34;

const unsigned long PUBLISH_INTERVAL = 10000;

const int SENSOR_DRY = 3000;
const int SENSOR_WET = 1200;

WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);

unsigned long lastPublish = 0;
String sensorTopic;

int readSensorPercent() {
  int raw = analogRead(SENSOR_PIN);
  int pct = map(raw, SENSOR_DRY, SENSOR_WET, 0, 100);
  pct = constrain(pct, 0, 100);
  return pct;
}

bool connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return true;
  Serial.print("WiFi: connecting");
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(500);
    Serial.print(".");
  }
  if (WiFi.status() == WL_CONNECTED) { Serial.println(" OK"); return true; }
  Serial.println(" FAILED");
  return false;
}

bool connectMQTT() {
  if (mqtt.connected()) return true;
  Serial.print("MQTT: connecting");
  String clientId = String(DEVICE_ID) + "_" + String((uint32_t)ESP.getEfuseMac(), HEX);
  unsigned long start = millis();
  while (!mqtt.connected() && millis() - start < 10000) {
    if (mqtt.connect(clientId.c_str(), MQTT_USER, MQTT_PASS)) {
      Serial.println(" OK");
      return true;
    }
    Serial.print(".");
    delay(500);
  }
  Serial.println(" FAILED");
  return false;
}

void publishSensor() {
  int value = readSensorPercent();
  char payload[96];
  snprintf(payload, sizeof(payload), "{\"%s\":%d}", SENSOR_ID, value);
  bool ok = mqtt.publish(sensorTopic.c_str(), payload);
  Serial.printf("Publish %s -> %d%% (%s)\n", SENSOR_ID, value, ok ? "ok" : "failed");
}

void setup() {
  Serial.begin(115200);
  delay(200);

  analogReadResolution(12);

  sensorTopic = String("tele/") + DEVICE_ID + "/SENSOR";
  mqtt.setServer(MQTT_HOST, MQTT_PORT);

  Serial.printf("Sensor node %s (%s) ready\n", DEVICE_ID, SENSOR_ID);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) connectWiFi();
  if (!mqtt.connected()) connectMQTT();
  mqtt.loop();

  if (mqtt.connected() && millis() - lastPublish >= PUBLISH_INTERVAL) {
    lastPublish = millis();
    publishSensor();
  }
}
