#version 460 core
// The develop pipeline: Lightroom-style non-destructive adjustments rendered
// on the GPU. The same shader draws the interactive preview and the
// full-resolution export, so what you see is exactly what you save.
#include <flutter/runtime_effect.glsl>

precision highp float;

// Uniform order is mirrored by DevelopShader in lib/services/shader_service.dart.
uniform vec2 uSize;        // output size (local pixels)
uniform vec2 uImageSize;   // source image size (pixels)
uniform vec4 uCrop;        // normalised crop of the rotated image: l, t, w, h
uniform float uRotation;   // radians, clockwise

// Light
uniform float uExposure;   // EV
uniform float uContrast;   // -1..1
uniform float uHighlights; // -1..1
uniform float uShadows;    // -1..1
uniform float uWhites;     // -1..1
uniform float uBlacks;     // -1..1
// Colour
uniform float uTemp;       // -1..1
uniform float uTint;       // -1..1
uniform float uVibrance;   // -1..1
uniform float uSaturation; // -1..1
// Effects / detail
uniform float uClarity;    // -1..1
uniform float uDehaze;     // -1..1
uniform float uVignette;   // -1..1
uniform float uGrain;      // 0..1
uniform float uGrainSize;  // 0..1
uniform float uSharpness;  // 0..1.5
// HSL: 8 bands packed in pairs of vec4 (red..green, aqua..magenta)
uniform vec4 uHueA;
uniform vec4 uHueB;
uniform vec4 uSatA;
uniform vec4 uSatB;
uniform vec4 uLumA;
uniform vec4 uLumB;
// Colour grading
uniform vec3 uShadowTint;
uniform vec3 uHighlightTint;
uniform float uGradeBalance; // -1..1
// LUT & curves
uniform float uLutSize;
uniform float uLutMix;
uniform float uLutLogInput;
uniform float uCurveEnabled;

uniform sampler2D uImage;
uniform sampler2D uLut;
uniform sampler2D uCurve; // 256 x 1, per-channel composite curves in RGB

out vec4 fragColor;

const float AF_A = 0.075;
const float AF_OFFSET = 0.01;
const float AF_B = 0.5996947;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// Centre hues of the eight HSL bands (keep in sync with HslBand).
float bandHue(int i) {
  if (i == 0) return 0.0;
  if (i == 1) return 30.0;
  if (i == 2) return 60.0;
  if (i == 3) return 120.0;
  if (i == 4) return 180.0;
  if (i == 5) return 225.0;
  if (i == 6) return 270.0;
  return 315.0;
}

float pick(vec4 a, vec4 b, int i) {
  if (i == 0) return a.x;
  if (i == 1) return a.y;
  if (i == 2) return a.z;
  if (i == 3) return a.w;
  if (i == 4) return b.x;
  if (i == 5) return b.y;
  if (i == 6) return b.z;
  return b.w;
}

vec3 srgbToLinear(vec3 c) {
  c = max(c, vec3(0.0));
  vec3 lo = c / 12.92;
  vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
  return mix(lo, hi, step(vec3(0.04045), c));
}

vec3 linearToSrgb(vec3 c) {
  c = max(c, vec3(0.0));
  vec3 lo = c * 12.92;
  vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
  return mix(lo, hi, step(vec3(0.0031308), c));
}

vec3 afLogFromSrgb(vec3 c) {
  vec3 lin = srgbToLinear(clamp(c, 0.0, 1.0));
  lin = min(lin, vec3(0.995));
  lin = lin / (1.0 - lin * 0.75);
  return clamp(AF_A * log2(lin + AF_OFFSET) + AF_B, 0.0, 1.0);
}

vec3 rgb2hsv(vec3 c) {
  vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
  vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
  vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
  float d = q.x - min(q.w, q.y);
  float e = 1.0e-10;
  return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
  vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
  vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
  return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// Smooth value noise for film grain clumps.
float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash12(i);
  float b = hash12(i + vec2(1.0, 0.0));
  float c = hash12(i + vec2(0.0, 1.0));
  float d = hash12(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

vec3 lutTexel(vec3 idx) {
  float n = uLutSize;
  vec2 uv = vec2((idx.b * n + idx.r + 0.5) / (n * n), (idx.g + 0.5) / n);
  return texture(uLut, uv).rgb;
}

vec3 applyLut(vec3 c) {
  float n1 = uLutSize - 1.0;
  vec3 p = clamp(c, 0.0, 1.0) * n1;
  vec3 i0 = min(floor(p), vec3(n1 - 1.0));
  vec3 t = p - i0;
  vec3 c00 = mix(lutTexel(i0), lutTexel(i0 + vec3(1, 0, 0)), t.r);
  vec3 c10 = mix(lutTexel(i0 + vec3(0, 1, 0)), lutTexel(i0 + vec3(1, 1, 0)), t.r);
  vec3 c01 = mix(lutTexel(i0 + vec3(0, 0, 1)), lutTexel(i0 + vec3(1, 0, 1)), t.r);
  vec3 c11 = mix(lutTexel(i0 + vec3(0, 1, 1)), lutTexel(i0 + vec3(1, 1, 1)), t.r);
  return mix(mix(c00, c10, t.g), mix(c01, c11, t.g), t.b);
}

float curveLookup(float v, int ch) {
  vec4 s = texture(uCurve, vec2(clamp(v, 0.0, 1.0) * (255.0 / 256.0) + 0.5 / 256.0, 0.5));
  return ch == 0 ? s.r : (ch == 1 ? s.g : s.b);
}

// Contrast that pins black and white: power curve on each half.
float contrastCurve(float x, float k) {
  x = clamp(x, 0.0, 1.0);
  return x < 0.5 ? 0.5 * pow(2.0 * x, k) : 1.0 - 0.5 * pow(2.0 * (1.0 - x), k);
}

float hueDistance(float a, float b) {
  float d = abs(a - b);
  return min(d, 360.0 - d);
}

// Map an output pixel to source image UV through crop + rotation.
vec2 sourceUv(vec2 outUv) {
  vec2 p = (uCrop.xy + outUv * uCrop.zw) * uImageSize;
  vec2 centre = uImageSize * 0.5;
  vec2 d = p - centre;
  float c = cos(-uRotation), s = sin(-uRotation);
  vec2 src = centre + vec2(d.x * c - d.y * s, d.x * s + d.y * c);
  return src / uImageSize;
}

vec3 sampleSrc(vec2 uv) {
  return texture(uImage, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 outUv = frag / uSize;
  vec2 uv = sourceUv(outUv);
  vec3 c = sampleSrc(uv);

  // ---- Detail (computed on source luminance) ---------------------------
  vec2 texel = 1.0 / uImageSize;
  float srcL = luma(c);
  float detail = 0.0;
  if (abs(uClarity) > 0.001) {
    float r = 0.012 * min(uImageSize.x, uImageSize.y);
    float acc = 0.0;
    for (int i = 0; i < 12; i++) {
      float a = float(i) * 0.5235988; // 30 degrees
      float rr = (i - (i / 2) * 2 == 0) ? r : r * 0.5;
      acc += luma(sampleSrc(uv + vec2(cos(a), sin(a)) * rr * texel));
    }
    detail = srcL - acc / 12.0;
  }
  float sharpDetail = 0.0;
  if (uSharpness > 0.001) {
    float n = luma(sampleSrc(uv + vec2(0.0, -1.0) * texel));
    float so = luma(sampleSrc(uv + vec2(0.0, 1.0) * texel));
    float e = luma(sampleSrc(uv + vec2(1.0, 0.0) * texel));
    float w = luma(sampleSrc(uv + vec2(-1.0, 0.0) * texel));
    sharpDetail = srcL - (n + so + e + w) * 0.25;
  }

  // ---- White balance & exposure (linear light) -------------------------
  vec3 lin = srgbToLinear(c);
  vec3 wb = vec3(1.0 + 0.22 * uTemp, 1.0, 1.0 - 0.22 * uTemp);
  wb *= vec3(1.0 + 0.08 * uTint, 1.0 - 0.16 * uTint, 1.0 + 0.08 * uTint);
  wb /= luma(wb);
  lin *= wb * exp2(uExposure);

  // Dehaze: remove (or add) an airlight veil estimated from the dark channel.
  if (abs(uDehaze) > 0.001) {
    float dark = min(lin.r, min(lin.g, lin.b));
    float veil = uDehaze * 0.6 * smoothstep(0.0, 0.6, dark) * 0.25;
    lin = max((lin - veil) / max(1.0 - veil, 0.2), vec3(0.0));
  }

  vec3 col = linearToSrgb(lin);

  // ---- Tone (luminance-domain, hue-preserving) ------------------------
  float L = luma(col);
  float L0 = max(L, 1e-4);
  L += uShadows * 0.32 * (1.0 - smoothstep(0.0, 0.55, L)) * (0.12 + L);
  L += uHighlights * 0.38 * smoothstep(0.4, 1.0, L) * min(L, 1.3);
  L += uWhites * 0.22 * smoothstep(0.55, 1.0, L);
  L += uBlacks * 0.10 * (1.0 - smoothstep(0.0, 0.32, L));
  // Clarity: midtone-weighted local contrast.
  float mid = 1.0 - abs(L - 0.5) * 2.0;
  L += uClarity * detail * 2.2 * clamp(mid + 0.2, 0.0, 1.0);
  L += uSharpness * sharpDetail * 1.6;
  // Soft-clip HDR values from +exposure back under 1.0. Faded in with
  // exposure so neutral settings stay an exact identity.
  float knee = clamp(uExposure * 2.0, 0.0, 1.0);
  if (L > 0.85) L = mix(L, 0.85 + 0.15 * tanh((L - 0.85) / 0.15), knee);
  L = max(L, 0.0);
  float k = uContrast >= 0.0 ? 1.0 + uContrast * 1.1 : 1.0 + uContrast * 0.6;
  L = contrastCurve(L, k);
  col *= L / L0;
  // Bring overflowing channels back toward luminance instead of hard-clipping hue.
  float maxC = max(col.r, max(col.g, col.b));
  if (maxC > 1.0) col = mix(vec3(L), col, (1.0 - L) / max(maxC - L, 1e-4));
  if (uDehaze > 0.0) col = mix(vec3(luma(col)), col, 1.0 + uDehaze * 0.25);

  // ---- Presence: vibrance & saturation ---------------------------------
  float lum = luma(col);
  float sat = max(col.r, max(col.g, col.b)) - min(col.r, min(col.g, col.b));
  vec3 hsvSkin = rgb2hsv(clamp(col, 0.0, 1.0));
  float skin = 1.0 - smoothstep(10.0, 35.0, hueDistance(hsvSkin.x * 360.0, 25.0));
  float vib = uVibrance * (1.0 - sat) * (1.0 - 0.5 * skin);
  col = mix(vec3(lum), col, 1.0 + vib);
  col = mix(vec3(lum), col, 1.0 + uSaturation);

  // ---- HSL --------------------------------------------------------------
  vec3 hsv = rgb2hsv(clamp(col, 0.0, 1.0));
  float hueDeg = hsv.x * 360.0;
  float dh = 0.0, ds = 0.0, dl = 0.0, wsum = 0.0;
  for (int i = 0; i < 8; i++) {
    float w = max(0.0, 1.0 - hueDistance(hueDeg, bandHue(i)) / 45.0);
    w = w * w * (3.0 - 2.0 * w);
    float hh = pick(uHueA, uHueB, i);
    float ss = pick(uSatA, uSatB, i);
    float ll = pick(uLumA, uLumB, i);
    dh += hh * w;
    ds += ss * w;
    dl += ll * w;
    wsum += w;
  }
  if (wsum > 0.0) {
    dh /= max(wsum, 1.0);
    ds /= max(wsum, 1.0);
    dl /= max(wsum, 1.0);
    float chroma = smoothstep(0.02, 0.25, hsv.y);
    hsv.x = fract(hsv.x + dh * 30.0 / 360.0 * chroma);
    hsv.y = clamp(hsv.y * (1.0 + ds), 0.0, 1.0);
    hsv.z = clamp(hsv.z * (1.0 + dl * 0.45 * chroma), 0.0, 1.0);
    col = hsv2rgb(hsv);
  }

  // ---- Colour grading ---------------------------------------------------
  float gl = luma(col);
  float bal = uGradeBalance * 0.35;
  float wShadow = 1.0 - smoothstep(0.0, 0.6 + bal, gl);
  float wHigh = smoothstep(0.4 + bal, 1.0, gl);
  col += uShadowTint * wShadow + uHighlightTint * wHigh;

  // ---- Tone curve -------------------------------------------------------
  if (uCurveEnabled > 0.5) {
    col = vec3(curveLookup(col.r, 0), curveLookup(col.g, 1), curveLookup(col.b, 2));
  }

  // ---- LUT ---------------------------------------------------------------
  if (uLutMix > 0.0) {
    vec3 lutIn = uLutLogInput > 0.5 ? afLogFromSrgb(col) : col;
    col = mix(col, applyLut(lutIn), uLutMix);
  }

  // ---- Vignette (relative to the cropped frame) ---------------------------
  if (abs(uVignette) > 0.001) {
    vec2 d = (outUv - 0.5) * vec2(uSize.x / max(uSize.x, uSize.y), uSize.y / max(uSize.x, uSize.y)) * 2.0;
    float v = smoothstep(0.35, 1.25, length(d));
    col = uVignette < 0.0 ? col * (1.0 + uVignette * 0.85 * v) : mix(col, vec3(1.0), uVignette * 0.7 * v);
  }

  // ---- Grain (anchored to source pixels so it scales with export) -----------
  if (uGrain > 0.001) {
    vec2 gp = uv * uImageSize / mix(1.0, 4.0, uGrainSize);
    float n = valueNoise(gp) * 0.6 + hash12(gp * 1.7) * 0.4 - 0.5;
    float gl2 = luma(col);
    float mask = 0.35 + 0.65 * (1.0 - abs(gl2 - 0.5) * 2.0);
    col += n * uGrain * 0.22 * mask;
  }

  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
