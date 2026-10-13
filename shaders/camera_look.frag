#version 460 core
// Live viewfinder look: AF-Log monitoring, LUT preview, zebras and focus
// peaking. Used as an ImageFilter over the camera preview, so the engine
// binds uSize and uTexture.
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uLutSize;      // N for an N^3 LUT laid out as an N*N x N atlas
uniform float uLutMix;       // 0 = no LUT, 1 = full LUT
uniform float uLogEncode;    // 1 = show the signal in AF-Log
uniform float uLutLogInput;  // 1 = LUT expects AF-Log input
uniform float uZebra;        // 1 = zebra stripes over clipped highlights
uniform float uPeaking;      // 1 = focus peaking
uniform float uTime;         // seconds, animates zebras

uniform sampler2D uTexture;  // camera preview (bound by the engine)
uniform sampler2D uLut;      // LUT atlas

out vec4 fragColor;

// --- AF-Log (keep in sync with lib/core/color/af_log.dart) ---------------
const float AF_A = 0.075;
const float AF_OFFSET = 0.01;
const float AF_B = 0.5996947;

vec3 srgbToLinear(vec3 c) {
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(lo, hi, step(vec3(0.04045), c));
}

vec3 expandHighlights(vec3 l) {
  l = min(l, vec3(0.995));
  return l / (1.0 - l * 0.75);
}

vec3 afLogFromSrgb(vec3 c) {
  vec3 lin = expandHighlights(srgbToLinear(clamp(c, 0.0, 1.0)));
  return clamp(AF_A * log2(lin + AF_OFFSET) + AF_B, 0.0, 1.0);
}

// --- LUT -------------------------------------------------------------------
vec3 lutTexel(vec3 idx) {
  float n = uLutSize;
  vec2 uv = vec2((idx.b * n + idx.r + 0.5) / (n * n), (idx.g + 0.5) / n);
  return texture(uLut, uv).rgb;
}

// Manual trilinear: eight texel-centre taps, independent of sampler filtering.
vec3 applyLut(vec3 c) {
  float n1 = uLutSize - 1.0;
  vec3 p = clamp(c, 0.0, 1.0) * n1;
  vec3 i0 = min(floor(p), vec3(n1 - 1.0));
  vec3 t = p - i0;
  vec3 c000 = lutTexel(i0);
  vec3 c100 = lutTexel(i0 + vec3(1, 0, 0));
  vec3 c010 = lutTexel(i0 + vec3(0, 1, 0));
  vec3 c110 = lutTexel(i0 + vec3(1, 1, 0));
  vec3 c001 = lutTexel(i0 + vec3(0, 0, 1));
  vec3 c101 = lutTexel(i0 + vec3(1, 0, 1));
  vec3 c011 = lutTexel(i0 + vec3(0, 1, 1));
  vec3 c111 = lutTexel(i0 + vec3(1, 1, 1));
  vec3 c00 = mix(c000, c100, t.r);
  vec3 c10 = mix(c010, c110, t.r);
  vec3 c01 = mix(c001, c101, t.r);
  vec3 c11 = mix(c011, c111, t.r);
  return mix(mix(c00, c10, t.g), mix(c01, c11, t.g), t.b);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec2 flipUv(vec2 uv) {
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = flipUv(frag / uSize);
  vec4 src = texture(uTexture, uv);
  vec3 c = src.rgb;
  vec3 original = c;

  if (uLogEncode > 0.5) {
    c = afLogFromSrgb(c);
  }
  if (uLutMix > 0.0) {
    vec3 lutIn = (uLutLogInput > 0.5 && uLogEncode < 0.5) ? afLogFromSrgb(c) : c;
    c = mix(c, applyLut(lutIn), uLutMix);
  }

  if (uZebra > 0.5 && luma(original) > 0.96) {
    float stripe = step(0.5, fract((frag.x + frag.y + uTime * 40.0) / 14.0));
    c = mix(c, vec3(stripe), 0.65);
  }

  if (uPeaking > 0.5) {
    float l = luma(original);
    float lx = luma(texture(uTexture, flipUv((frag + vec2(1.5, 0.0)) / uSize)).rgb);
    float ly = luma(texture(uTexture, flipUv((frag + vec2(0.0, 1.5)) / uSize)).rgb);
    float edge = abs(lx - l) + abs(ly - l);
    float peak = smoothstep(0.10, 0.22, edge);
    c = mix(c, vec3(1.0, 0.15, 0.35), peak);
  }

  fragColor = vec4(c, 1.0) * src.a;
}
