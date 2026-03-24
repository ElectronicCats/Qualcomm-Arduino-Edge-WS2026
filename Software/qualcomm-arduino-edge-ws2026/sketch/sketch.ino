// SPDX-FileCopyrightText: Copyright (C) Electronic Cats
//
// SPDX-License-Identifier: MPL-2.0

#include <Adafruit_seesaw.h>
#include <seesaw_neopixel.h>
#include <Arduino_RouterBridge.h>

#define NEODRIVER_ADDR  0x60
#define NEO_PIN         15
#define NUM_PIXELS      5

seesaw_NeoPixel strip(NUM_PIXELS, NEO_PIN, NEO_GRB + NEO_KHZ800, &Wire1);

uint8_t brightness = 50;
uint8_t r = 255, g = 255, b = 255;

void setAll(uint8_t red, uint8_t green, uint8_t blue) {
  for (int i = 0; i < NUM_PIXELS; i++)
    strip.setPixelColor(i, strip.Color(red, green, blue));
  strip.show();
}

void setup() {
  if (!strip.begin(NEODRIVER_ADDR)) {
    while (1) delay(10);
  }
  strip.setBrightness(brightness);
  setAll(r, g, b);

  Bridge.begin();
  Bridge.provide("warmer_light", warmer_light);
  Bridge.provide("cooler_light", cooler_light);
  Bridge.provide("dimmer", dimmer);
  Bridge.provide("brighter", brighter);
}

void loop() {}

void warmer_light() {
  r = 255; g = 194; b = 138;
  setAll(r, g, b);
}

void cooler_light() {
  r = 144; g = 213; b = 255;
  setAll(r, g, b);
}

void dimmer() {
  brightness = (uint8_t)max(1, (int)(brightness * 0.6));
  strip.setBrightness(brightness);
  setAll(r, g, b);
}

void brighter() {
  brightness = (uint8_t)min(255, (int)(brightness * 1.4));
  strip.setBrightness(brightness);
  setAll(r, g, b);
}
